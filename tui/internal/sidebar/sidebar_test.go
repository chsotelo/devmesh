package sidebar

import (
	"context"
	"strings"
	"sync"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

const testWidth = 24

func init() {
	lipgloss.SetColorProfile(termenv.Ascii)
	tickCmd = func() tea.Cmd { return nil }
}

// fakeSource answers from memory and records what was asked.
type fakeSource struct {
	mu    sync.Mutex
	snap  feed.Snapshot
	shown string
	calls []string
}

func (f *fakeSource) FeedHost(context.Context, string) (feed.Snapshot, error) { return f.snap, nil }

func (f *fakeSource) Shown(context.Context, string) (string, error) { return f.shown, nil }

func (f *fakeSource) Show(_ context.Context, target source.PaneTarget) error {
	f.record("show " + target.Host + " " + target.Session + " " + target.Window + focusWord(target.Focus))
	return nil
}

func (f *fakeSource) Hold(_ context.Context, host, kind string) error {
	f.record("hold " + host + " " + kind)
	return nil
}

func (f *fakeSource) record(call string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call)
}

func focusWord(focus bool) string {
	if focus {
		return " focus"
	}
	return ""
}

func machine(reach feed.Reach, terms ...feed.Terminal) feed.Snapshot {
	return feed.Snapshot{Machines: []feed.Machine{{Name: "lap", Reach: reach, Terminals: terms}}}
}

func term(session, window string, agent feed.AgentState) feed.Terminal {
	return feed.Terminal{Host: "lap", Session: session, Window: window, Active: true, Agent: agent}
}

// loaded builds a sidebar that already read the snapshot; shown is what dm reports on screen.
func loaded(t *testing.T, src *fakeSource) *Model {
	t.Helper()
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback()})
	m.width, m.height = testWidth, 10
	return m
}

// poll applies a reading and runs the commands it returns, feeding results back.
func poll(m *Model, src *fakeSource) {
	cmd := m.applyPoll(pollMsg{snap: src.snap, shown: src.shown})
	run(m, cmd)
}

func run(m *Model, cmd tea.Cmd) {
	if cmd == nil {
		return
	}
	switch msg := cmd().(type) {
	case tea.BatchMsg:
		for _, inner := range msg {
			if inner != nil {
				run(m, inner)
			}
		}
	case doneMsg:
		m.Update(msg)
	}
}

func TestViewListsOneRowPerSessionWithinTheWidth(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline,
		term("api", "1", feed.AgentWaiting), term("web", "1", feed.AgentNone), term("a-very-long-session-name-x", "1", feed.AgentWorking)), shown: "api"}
	m := loaded(t, src)
	poll(m, src)

	view := m.View()
	lines := strings.Split(view, "\n")

	if len(lines) != 3 {
		t.Fatalf("want 3 rows, got %d:\n%s", len(lines), view)
	}
	for _, line := range lines {
		if got := lipgloss.Width(line); got > testWidth {
			t.Fatalf("line wider than the pane (%d): %q", got, line)
		}
	}
	if !strings.Contains(lines[0], "▎") || !strings.Contains(lines[0], ">_ api") {
		t.Fatalf("shown row = %q", lines[0])
	}
	if !strings.Contains(lines[2], "…") {
		t.Fatalf("long name must be cut: %q", lines[2])
	}
}

func TestOneRowPerSessionEvenWithSeveralWindows(t *testing.T) {
	snap := machine(feed.ReachOnline,
		feed.Terminal{Session: "api", Window: "1"},
		feed.Terminal{Session: "api", Window: "2", Active: true})

	rows := rowsOf(snap.Machines[0])

	if len(rows) != 1 || rows[0].Window != "2" {
		t.Fatalf("rows = %+v", rows)
	}
}

func TestFirstPollShowsTheFirstTerminalWithoutStealingFocus(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", feed.AgentNone), term("web", "1", feed.AgentNone))}
	m := loaded(t, src)

	poll(m, src)

	if got := strings.Join(src.calls, ";"); got != "show lap main 1" {
		t.Fatalf("calls = %q", got)
	}
}

func TestEnterAndClickShowTheRowAndFocusIt(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", feed.AgentNone), term("web", "2", feed.AgentNone)), shown: "main"}
	m := loaded(t, src)
	poll(m, src)

	m.Update(tea.KeyMsg{Type: tea.KeyDown})
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	run(m, cmd)
	_, cmd = m.Update(tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: 3, Y: 0})
	run(m, cmd)

	want := "show lap web 2 focus;show lap main 1 focus"
	if got := strings.Join(src.calls, ";"); got != want {
		t.Fatalf("calls = %q, want %q", got, want)
	}
}

func TestVimKeysMoveTheCursorWithinTheList(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("a", "1", ""), term("b", "1", ""), term("c", "1", "")), shown: "a"}
	m := loaded(t, src)
	poll(m, src)

	for _, key := range []string{"j", "j", "j", "k"} {
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
	}

	if m.cursor != 1 {
		t.Fatalf("cursor = %d, want 1", m.cursor)
	}
}

func TestOfflineAndEmptyMachinesShowAMessageAndHoldThePane(t *testing.T) {
	for _, tc := range []struct {
		name string
		snap feed.Snapshot
		view string
		call string
	}{
		{"offline", machine(feed.ReachOffline), "offline", "hold lap offline"},
		{"empty", machine(feed.ReachEmpty), "no terminals", "hold lap empty"},
	} {
		src := &fakeSource{snap: tc.snap}
		m := loaded(t, src)

		poll(m, src)
		poll(m, src)

		if !strings.Contains(m.View(), tc.view) {
			t.Fatalf("%s view = %q", tc.name, m.View())
		}
		if got := strings.Join(src.calls, ";"); got != tc.call {
			t.Fatalf("%s: calls = %q, want one %q", tc.name, got, tc.call)
		}
	}
}

func TestAShownTerminalThatVanishedIsReplacedAfterTwoPolls(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", "")), shown: "gone"}
	m := loaded(t, src)

	poll(m, src)
	if len(src.calls) != 0 {
		t.Fatalf("a terminal that is only being created must get a grace poll: %v", src.calls)
	}
	poll(m, src)

	if got := strings.Join(src.calls, ";"); got != "show lap main 1" {
		t.Fatalf("calls = %q", got)
	}
}

func TestWheelAndCursorKeepTheSelectionVisible(t *testing.T) {
	var terms []feed.Terminal
	for _, name := range []string{"a", "b", "c", "d", "e", "f"} {
		terms = append(terms, term(name, "1", ""))
	}
	src := &fakeSource{snap: machine(feed.ReachOnline, terms...), shown: "a"}
	m := loaded(t, src)
	m.height = 3
	poll(m, src)

	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("G")})

	lines := strings.Split(m.View(), "\n")
	if len(lines) != 3 || !strings.Contains(lines[2], "f") {
		t.Fatalf("view = %q", m.View())
	}
}

func TestActionErrorsShowOnTheLastLine(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("a", "1", "")), shown: "a"}
	m := loaded(t, src)
	poll(m, src)

	m.Update(doneMsg{err: context.DeadlineExceeded})

	lines := strings.Split(m.View(), "\n")
	if len(lines) != 2 || !strings.Contains(lines[1], "deadline") {
		t.Fatalf("view = %q", m.View())
	}
}

func TestRowsShowTheProgramNextToTheNameLikeVSCode(t *testing.T) {
	withCmd := func(session, command string) feed.Terminal {
		terminal := term(session, "1", feed.AgentNone)
		terminal.Command = command
		return terminal
	}
	src := &fakeSource{snap: machine(feed.ReachOnline,
		withCmd("api", "claude"), withCmd("a-long-session-name", "node")), shown: "api"}
	m := loaded(t, src)
	poll(m, src)

	lines := strings.Split(m.View(), "\n")
	if !strings.Contains(lines[0], "api  claude") {
		t.Fatalf("program must follow the name: %q", lines[0])
	}
	if strings.Contains(lines[1], "node") {
		t.Fatalf("no room for the program after a long name: %q", lines[1])
	}
	for _, line := range lines {
		if got := lipgloss.Width(line); got > testWidth {
			t.Fatalf("line wider than the pane (%d): %q", got, line)
		}
	}
}
