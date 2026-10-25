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

func (f *fakeSource) Act(_ context.Context, host, action string) error {
	f.record("act " + host + " " + action)
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
	m.width, m.height = testWidth, 30
	return m
}

// rowText is the line with the name of the i-th visible terminal.
func rowText(lines []string, i int) string {
	return lines[buttonLines+i*rowHeight+rowHeight/2]
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
	case pollMsg:
		run(m, m.applyPoll(msg))
	}
}

func TestViewListsOneRowPerSessionWithinTheWidth(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline,
		term("api", "1", feed.AgentWaiting), term("web", "1", feed.AgentNone), term("a-very-long-session-name-x", "1", feed.AgentWorking)), shown: "api"}
	m := loaded(t, src)
	poll(m, src)

	view := m.View()
	lines := strings.Split(view, "\n")

	if len(lines) != buttonLines+3*rowHeight {
		t.Fatalf("want the buttons and 3 rows, got %d:\n%s", len(lines), view)
	}
	for _, line := range lines {
		if got := lipgloss.Width(line); got > testWidth {
			t.Fatalf("line wider than the pane (%d): %q", got, line)
		}
	}
	if row := rowText(lines, 0); !strings.Contains(row, "▎") || !strings.Contains(row, ">_ api") {
		t.Fatalf("shown row = %q", row)
	}
	if !strings.Contains(lines[buttonLines], "▎") || strings.Contains(lines[buttonLines], "api") {
		t.Fatalf("the padding line above a row keeps its bar and has no text: %q", lines[buttonLines])
	}
	if row := rowText(lines, 2); !strings.Contains(row, "…") {
		t.Fatalf("long name must be cut: %q", row)
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
	_, cmd = m.Update(tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: 3, Y: buttonLines})
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

func TestBackOnlineTheTerminalShownBeforeComesBack(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", ""), term("api", "1", "")), shown: "api"}
	m := loaded(t, src)
	poll(m, src)

	src.snap = machine(feed.ReachOffline)
	poll(m, src)
	src.snap = machine(feed.ReachOnline, term("main", "1", ""), term("api", "1", ""))
	src.shown = ""
	poll(m, src)

	if got := strings.Join(src.calls, ";"); got != "hold lap offline;show lap api 1" {
		t.Fatalf("calls = %q", got)
	}
}

func TestAShownTerminalThatVanishedIsReplacedOnlyAfterAGracePeriod(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", "")), shown: "gone"}
	m := loaded(t, src)

	for range missesToSwap - 1 {
		poll(m, src)
	}
	if len(src.calls) != 0 {
		t.Fatalf("a terminal that is only being created must get a grace period: %v", src.calls)
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
	m.height = buttonLines + 3*rowHeight
	poll(m, src)

	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("G")})

	lines := strings.Split(m.View(), "\n")
	if len(lines) != buttonLines+3*rowHeight || !strings.Contains(rowText(lines, 2), "f") {
		t.Fatalf("view = %q", m.View())
	}
}

func TestActionErrorsShowOnTheLastLine(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("a", "1", "")), shown: "a"}
	m := loaded(t, src)
	poll(m, src)

	m.Update(doneMsg{err: context.DeadlineExceeded})

	lines := strings.Split(m.View(), "\n")
	if len(lines) != buttonLines+rowHeight+1 || !strings.Contains(lines[len(lines)-1], "deadline") {
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

	view := strings.Split(m.View(), "\n")
	lines := []string{rowText(view, 0), rowText(view, 1)}
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

func TestTheTopButtonsAndTheirKeysAddAndDeleteTerminals(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", "")), shown: "main"}
	m := loaded(t, src)
	poll(m, src)
	src.calls = nil
	buttons := m.buttons()

	for _, msg := range []tea.Msg{
		tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: buttons[0].from, Y: 0},
		tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: buttons[1].to - 1, Y: buttonHeight - 1},
		tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: 0, Y: 1},
		tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: buttons[0].from, Y: buttonHeight},
		tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("n")},
		tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("x")},
	} {
		_, cmd := m.Update(msg)
		run(m, cmd)
	}

	want := "act lap add;act lap delete;act lap add;act lap delete"
	if got := strings.Join(src.calls, ";"); got != want {
		t.Fatalf("calls = %q, want %q", got, want)
	}
}

func TestButtonsAreTallBoxesThatFillTheListWidthWithTheLabelCentered(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("main", "1", "")), shown: "main"}
	m := loaded(t, src)
	poll(m, src)

	lines := strings.Split(m.View(), "\n")
	buttons := m.buttons()

	for line := 0; line < buttonHeight; line++ {
		if got := lipgloss.Width(lines[line]); got != testWidth-buttonMargin {
			t.Fatalf("button line %d is %d wide: %q", line, got, lines[line])
		}
	}
	if strings.TrimSpace(lines[0]) != "" || strings.TrimSpace(lines[buttonHeight-1]) != "" {
		t.Fatalf("the padding lines must be empty: %q", lines[:buttonHeight])
	}
	middle := lines[buttonHeight/2]
	if !strings.Contains(middle, "+ New") || !strings.Contains(middle, "Delete") {
		t.Fatalf("labels line = %q", middle)
	}
	if at := strings.Index(middle, "+ New"); at <= buttons[0].from {
		t.Fatalf("the label must have padding before it: %q", middle)
	}
	if lines[buttonHeight] != "" {
		t.Fatalf("an empty line must separate the buttons from the list: %q", lines[buttonHeight])
	}
}

// fakeMemory is a remembered reading and a count of saves.
type fakeMemory struct {
	saved Saved
	has   bool
	saves int
}

func (f *fakeMemory) Load(string) (Saved, bool) { return f.saved, f.has }

func (f *fakeMemory) Save(_ string, saved Saved) {
	f.saved, f.has = saved, true
	f.saves++
}

func TestARememberedListDrawsAtOnceAndPutsItsTerminalOnScreenBeforeReading(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("api", "1", ""), term("web", "2", "")), shown: "web"}
	mem := &fakeMemory{has: true, saved: Saved{Rows: []Row{{Session: "api", Window: "1"}, {Session: "web", Window: "2"}}, Online: true, Shown: "web"}}
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback(), Memory: mem})
	m.width, m.height = testWidth, 10

	view := m.View()
	if strings.Contains(view, "Loading") || !strings.Contains(view, ">_ web") {
		t.Fatalf("view before any reading = %q", view)
	}
	if m.cursor != 1 {
		t.Fatalf("cursor = %d, want the remembered terminal", m.cursor)
	}
	run(m, m.Init())

	if got := strings.Join(src.calls, ";"); got != "show lap web 2" {
		t.Fatalf("calls = %q", got)
	}
}

func TestTheReadingIsRememberedOnlyWhenItChanges(t *testing.T) {
	src := &fakeSource{snap: machine(feed.ReachOnline, term("api", "1", "")), shown: "api"}
	mem := &fakeMemory{}
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback(), Memory: mem})
	m.width, m.height = testWidth, 10

	poll(m, src)
	poll(m, src)
	src.snap = machine(feed.ReachOnline, term("api", "1", ""), term("new", "1", ""))
	poll(m, src)

	if mem.saves != 2 || len(mem.saved.Rows) != 2 || mem.saved.Shown != "api" {
		t.Fatalf("saves = %d, saved = %+v", mem.saves, mem.saved)
	}
}

func TestATapAnywhereOnARowChoosesItAndALongListShowsAScrollbar(t *testing.T) {
	var terms []feed.Terminal
	for _, name := range []string{"a", "b", "c", "d", "e", "f"} {
		terms = append(terms, term(name, "1", ""))
	}
	src := &fakeSource{snap: machine(feed.ReachOnline, terms...), shown: "a"}
	m := loaded(t, src)
	m.height = buttonLines + 3*rowHeight
	poll(m, src)

	lines := strings.Split(m.View(), "\n")
	if !strings.HasSuffix(lines[buttonLines], scrollThumb) || !strings.HasSuffix(lines[len(lines)-1], scrollTrack) {
		t.Fatalf("scrollbar: %q", lines[buttonLines:])
	}
	for _, y := range []int{buttonLines + rowHeight, buttonLines + 2*rowHeight - 1} {
		_, cmd := m.Update(tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: 5, Y: y})
		run(m, cmd)
	}
	if got := strings.Join(src.calls, ";"); got != "show lap b 1 focus;show lap b 1 focus" {
		t.Fatalf("calls = %q", got)
	}
	m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelDown})
	if m.top != 1 {
		t.Fatalf("wheel moves the list one terminal: top = %d", m.top)
	}
}
