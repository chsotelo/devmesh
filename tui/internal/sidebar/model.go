// Package sidebar is the list of terminals of one machine, the left side of the layout:
// a plain VS Code like list (icon, name, agent dot). It only draws; choosing a row asks
// dm to show that terminal in the right pane.
package sidebar

import (
	"context"
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
}

// Options are what the sidebar needs from the outside.
type Options struct {
	Host    string
	Source  Source
	Catalog i18n.Catalog
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

// New returns the model of the list of a machine.
func New(opts Options) *Model {
	return &Model{
		host:   opts.Host,
		src:    opts.Source,
		cat:    opts.Catalog,
		width:  defaultWidth,
		height: defaultHeight,
	}
}

// Init reads the machine right away.
func (m *Model) Init() tea.Cmd {
	m.polling = true
	return m.pollCmd()
}

func (m *Model) pollCmd() tea.Cmd {
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), pollBudget)
		defer cancel()
		snap, err := src.FeedHost(ctx, host)
		if err != nil {
			return pollMsg{err: err}
		}
		shown, err := src.Shown(ctx, host)
		return pollMsg{snap: snap, shown: shown, err: err}
	}
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
