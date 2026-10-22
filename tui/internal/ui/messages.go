package ui

import (
	"context"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

// feedMsg carries one reading of the mesh. seq tells which request it answers.
type feedMsg struct {
	seq  int
	snap feed.Snapshot
	err  error
}

// shotMsg carries the live screen of one terminal for request id.
type shotMsg struct {
	key   string
	id    int
	lines []string
	err   error
}

type feedTickMsg struct{}

type shotTickMsg struct{}

// projectsMsg carries the project folders of a machine.
type projectsMsg struct {
	host  string
	names []string
	err   error
}

type devicesMsg struct {
	text string
	err  error
}

// actionMsg is the end of a background action (open a tab, refresh, create).
type actionMsg struct {
	err    error
	reload bool
	goHome bool
	next   tea.Cmd
}

// execDoneMsg is the end of a full screen command: the panel is back on screen.
type execDoneMsg struct {
	err    error
	goHome bool
}

// feedTick and shotTick arm the two refresh rhythms; tests replace them.
var (
	feedTick = func() tea.Cmd {
		return tea.Tick(feedEvery, func(time.Time) tea.Msg { return feedTickMsg{} })
	}
	shotTick = func() tea.Cmd {
		return tea.Tick(shotEvery, func(time.Time) tea.Msg { return shotTickMsg{} })
	}
)

// fetchFeed asks for a new reading. Results of older requests are dropped by seq.
func (m *Model) fetchFeed() tea.Cmd {
	m.feedSeq++
	m.feedBusy = true
	seq, reader := m.feedSeq, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), feedBudget)
		defer cancel()
		snap, err := reader.Feed(ctx)
		return feedMsg{seq: seq, snap: snap, err: err}
	}
}

// fetchShot reads the live screen of one terminal.
func (m *Model) fetchShot(term feed.Terminal) tea.Cmd {
	m.shotCounter++
	id, key, reader := m.shotCounter, term.Key(), m.src
	m.inflight[key] = id
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), shotBudget)
		defer cancel()
		lines, err := reader.Shot(ctx, term.Host, term.Session, term.Window)
		return shotMsg{key: key, id: id, lines: lines, err: err}
	}
}

func (m *Model) fetchProjects(host string) tea.Cmd {
	reader := m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), listBudget)
		defer cancel()
		names, err := reader.Projects(ctx, host)
		return projectsMsg{host: host, names: names, err: err}
	}
}

func (m *Model) fetchDevices() tea.Cmd {
	m.devicesBusy = true
	reader := m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), listBudget)
		defer cancel()
		text, err := reader.Devices(ctx)
		return devicesMsg{text: text, err: err}
	}
}

// backgroundAction runs fn off the UI loop and reports its end as an actionMsg.
func backgroundAction(fn func(ctx context.Context) error, done actionMsg) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), actionBudget)
		defer cancel()
		done.err = fn(ctx)
		return done
	}
}

// failure formats an error for the status line.
func (m *Model) failure(err error) string {
	return m.cat.Format(i18n.KeyActionFailed, feed.Clean(err.Error()))
}
