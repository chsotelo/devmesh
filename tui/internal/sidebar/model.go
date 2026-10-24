// Package sidebar is the list of terminals of one machine, the left side of the layout:
// a plain VS Code like list (icon, name, agent dot). It only draws; choosing a row asks
// dm to show that terminal in the right pane.
package sidebar

import (
	"context"
	"reflect"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

const (
	pollEvery     = 3 * time.Second
	pollBudget    = 40 * time.Second
	actionBudget  = 40 * time.Second
	missesToSwap  = 2
	defaultWidth  = 24
	defaultHeight = 30
)

// Source is what the sidebar needs from dm.
type Source interface {
	FeedHost(ctx context.Context, host string) (feed.Snapshot, error)
	Shown(ctx context.Context, host string) (string, error)
	Show(ctx context.Context, target source.PaneTarget) error
	Hold(ctx context.Context, host, kind string) error
	Act(ctx context.Context, host, action string) error
}

// Memory keeps the last reading of a machine between runs, so a new list draws it at once
// instead of a loading message (nil: no memory).
type Memory interface {
	Load(host string) (Saved, bool)
	Save(host string, saved Saved)
}

// Saved is what the list remembers of a machine.
type Saved struct {
	Rows   []Row
	Color  int
	Online bool
	Shown  string
}

// Options are what the sidebar needs from the outside.
type Options struct {
	Host    string
	Source  Source
	Catalog i18n.Catalog
	Memory  Memory
}

// Row is one terminal of the machine.
type Row struct {
	Session string
	Window  string
	Command string
	Agent   feed.AgentState
}

// Model is the Bubble Tea model of the sidebar.
type Model struct {
	host string
	src  Source
	cat  i18n.Catalog
	mem  Memory
	kept Saved

	width  int
	height int
	top    int

	rows    []Row
	cursor  int
	shown   string
	color   int
	loaded  bool
	online  bool
	polling bool
	held    string
	misses  int
	err     string
}

type tickMsg struct{}

type pollMsg struct {
	snap  feed.Snapshot
	shown string
	err   error
}

type doneMsg struct{ err error }

// New returns the model of the list of a machine, with its last reading when there is one.
func New(opts Options) *Model {
	m := &Model{
		host:   opts.Host,
		src:    opts.Source,
		cat:    opts.Catalog,
		mem:    opts.Memory,
		width:  defaultWidth,
		height: defaultHeight,
	}
	if m.mem == nil {
		return m
	}
	if saved, ok := m.mem.Load(m.host); ok {
		m.kept = saved
		m.rows, m.color, m.online, m.shown = saved.Rows, saved.Color, saved.Online, saved.Shown
		m.cursor = max(indexOf(m.rows, m.shown), 0)
		m.loaded = true
	}
	return m
}

// Init reads the machine right away. With a remembered terminal it first puts that one on
// screen (the reading over the network can take seconds); the reading then corrects it.
func (m *Model) Init() tea.Cmd {
	m.polling = true
	if at := indexOf(m.rows, m.shown); m.online && at >= 0 {
		return m.showThenPollCmd(m.rows[at])
	}
	return m.pollCmd()
}

// showThenPollCmd shows a terminal, then reads the machine. A failed show needs no report:
// the reading finds nothing on screen and decide() picks a terminal.
func (m *Model) showThenPollCmd(row Row) tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		_ = src.Show(ctx, source.PaneTarget{Host: host, Session: row.Session, Window: row.Window})
		cancel()
		return readMachine(src, host)
	}
}

// remember stores the reading when it changed.
func (m *Model) remember() tea.Cmd {
	saved := Saved{Rows: m.rows, Color: m.color, Online: m.online, Shown: m.shown}
	if m.mem == nil || reflect.DeepEqual(saved, m.kept) {
		return nil
	}
	m.kept = saved
	mem, host := m.mem, m.host
	return func() tea.Msg {
		mem.Save(host, saved)
		return nil
	}
}

func (m *Model) pollCmd() tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg { return readMachine(src, host) }
}

func readMachine(src Source, host string) pollMsg {
	ctx, cancel := context.WithTimeout(context.Background(), pollBudget)
	defer cancel()
	snap, err := src.FeedHost(ctx, host)
	if err != nil {
		return pollMsg{err: err}
	}
	shown, err := src.Shown(ctx, host)
	return pollMsg{snap: snap, shown: shown, err: err}
}

func (m *Model) showCmd(row Row, focus bool) tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		defer cancel()
		return doneMsg{err: src.Show(ctx, source.PaneTarget{Host: host, Session: row.Session, Window: row.Window, Focus: focus})}
	}
}

func (m *Model) holdCmd(kind string) tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		defer cancel()
		return doneMsg{err: src.Hold(ctx, host, kind)}
	}
}

func (m *Model) actCmd(action string) tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		defer cancel()
		return doneMsg{err: src.Act(ctx, host, action)}
	}
}

// tickCmd waits for the next poll; tests replace it (a real wait would last seconds).
var tickCmd = func() tea.Cmd {
	return tea.Tick(pollEvery, func(time.Time) tea.Msg { return tickMsg{} })
}

// rowsOf lists one row per session: the active window of each.
func rowsOf(machine feed.Machine) []Row {
	var rows []Row
	index := map[string]int{}
	for _, term := range machine.Terminals {
		position, seen := index[term.Session]
		switch {
		case !seen:
			index[term.Session] = len(rows)
			rows = append(rows, rowOf(term))
		case term.Active:
			rows[position] = rowOf(term)
		}
	}
	return rows
}

func rowOf(term feed.Terminal) Row {
	return Row{Session: term.Session, Window: term.Window, Command: term.Command, Agent: term.Agent}
}

func indexOf(rows []Row, session string) int {
	for i, row := range rows {
		if row.Session == session {
			return i
		}
	}
	return -1
}
