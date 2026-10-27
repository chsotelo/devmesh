package sidebar

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

const (
	idWorking = "00000000-0000-4000-8000-000000000001"
	idIdle    = "00000000-0000-4000-8000-000000000002"
	idStale   = "00000000-0000-4000-8000-000000000003"
	idOutside = "00000000-0000-4000-8000-000000000004"
	idPast    = "00000000-0000-4000-8000-000000000005"
	idPastTwo = "00000000-0000-4000-8000-000000000006"
)

func live(id string, status feed.ClaudeStatus, idle int64, tmux string, mb int, name string) feed.ClaudeSession {
	return feed.ClaudeSession{Machine: "lap", ID: id, Status: status, IdleSecs: idle, Tmux: tmux, RSSMB: mb, Cwd: "/home/u/x", Name: name}
}

// claudeMachine is "lap" with four live sessions (one outside tmux) and two stopped ones.
func claudeMachine() feed.Machine {
	return feed.Machine{Name: "lap", Reach: feed.ReachOnline, Color: 33, HasClaude: true, ClaudeKnown: true,
		Terminals: []feed.Terminal{term("main", "2", ""), term("s2", "1", ""), term("s3", "4", "")},
		Claude: []feed.ClaudeSession{
			live(idStale, feed.ClaudeIdle, 273*60, "s3:@4.%0", 67, "26Oct - calendario"),
			live(idOutside, feed.ClaudeIdle, 3*86400, "", 14, "24Oct - villa"),
			live(idIdle, feed.ClaudeIdle, 20*60, "s2:@1.%0", 62, "19Oct - mytools"),
			live(idWorking, feed.ClaudeWorking, 4, "main:@2.%1", 262, "27Oct - tools"),
		},
		History: []feed.ClaudeHistory{
			{Machine: "lap", ID: idPast, AgeSecs: 3600, Name: "18Oct - form guide"},
			{Machine: "lap", ID: idPastTwo, AgeSecs: 3 * 86400, Name: "13Oct - document skill"},
		}}
}

// meshOf is the whole mesh: lap plus the other machines (name, reach, hasClaude, MB).
func meshOf(others ...feed.Machine) feed.Snapshot {
	return feed.Snapshot{Machines: append([]feed.Machine{claudeMachine()}, others...)}
}

func other(name string, reach feed.Reach, hasClaude bool, mb int) feed.Machine {
	machine := feed.Machine{Name: name, Reach: reach, HasClaude: hasClaude, ClaudeKnown: true, Color: 40}
	if mb > 0 {
		machine.Claude = []feed.ClaudeSession{{Machine: name, ID: "ffffffff-0000-4000-8000-000000000000", RSSMB: mb}}
	}
	return machine
}

// claudeModel is a sidebar on the Claude home that read the machine and the mesh.
func claudeModel(t *testing.T, width, height int, others ...feed.Machine) (*Model, *fakeSource) {
	t.Helper()
	snap := feed.Snapshot{Machines: []feed.Machine{claudeMachine()}}
	src := &fakeSource{snap: snap, shown: "main", mesh: meshOf(others...), projects: []string{"api", "docs"}, session: "fresh"}
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback()})
	m.width, m.height = width, height
	poll(m, src)
	m.applyMesh(meshMsg{snap: src.mesh})
	src.calls = nil
	return m, src
}

func tapAt(m *Model, x, y int) {
	_, cmd := m.Update(tea.MouseMsg{Action: tea.MouseActionPress, Button: tea.MouseButtonLeft, X: x, Y: y})
	run(m, cmd)
}

// tapText taps the first line of the view that contains text.
func tapText(t *testing.T, m *Model, text string) {
	t.Helper()
	for y, line := range strings.Split(m.View(), "\n") {
		if at := strings.Index(line, text); at >= 0 {
			tapAt(m, len([]rune(line[:at])), y)
			return
		}
	}
	t.Fatalf("%q is not on screen:\n%s", text, m.View())
}

func key(name string) tea.KeyMsg {
	switch name {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(name)}
}

func send(m *Model, names ...string) {
	for _, name := range names {
		_, cmd := m.Update(key(name))
		run(m, cmd)
	}
}

func typeText(m *Model, text string) {
	for _, r := range text {
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
}

func fits(t *testing.T, m *Model) {
	t.Helper()
	for i, line := range strings.Split(m.View(), "\n") {
		if got := m.textWidth(line); got > m.width {
			t.Fatalf("line %d is %d cells wide in %d: %q", i, got, m.width, line)
		}
	}
}

func TestHomeListsClaudeSessionsWorkingFirstThenIdleByIdleTime(t *testing.T) {
	m, _ := claudeModel(t, 44, 30)

	view := m.View()

	last := -1
	for _, name := range []string{"27Oct - tools", "19Oct - mytools", "26Oct - calendario", "24Oct - villa"} {
		at := strings.Index(view, name)
		if at < 0 || at <= last {
			t.Fatalf("%q out of order:\n%s", name, view)
		}
		last = at
	}
	for _, want := range []string{"working", "20 min", "4 h", "3 d"} {
		if !strings.Contains(view, want) {
			t.Errorf("home lacks %q:\n%s", want, view)
		}
	}
	fits(t, m)
}

func TestEachSessionIsOneLineWithTheNameCutAndTheWordRightAligned(t *testing.T) {
	m, _ := claudeModel(t, 32, 30)
	m.claude.machine.Claude[3].Name = "27Oct - a very long session name"

	lines := strings.Split(m.View(), "\n")

	first, second := lines[1], lines[2]
	if !strings.Contains(first, "27Oct - a very") || !strings.Contains(first, "…") || !strings.HasSuffix(strings.TrimRight(first, " "), "working") {
		t.Fatalf("working row = %q\n%s", first, m.View())
	}
	if !strings.Contains(second, "19Oct - mytools") || !strings.HasSuffix(strings.TrimRight(second, " "), "20 min") {
		t.Fatalf("idle row = %q\n%s", second, m.View())
	}
	if !strings.HasPrefix(first, "▌●") || !strings.HasPrefix(second, " ○") {
		t.Fatalf("a working row is a filled dot, an idle one a hollow dot: %q %q", first, second)
	}
	fits(t, m)
}

func TestTheOpenSessionIsMarkedAndTheCursorRowStaysVisible(t *testing.T) {
	m, _ := claudeModel(t, 32, 30)
	send(m, "down") // the cursor leaves the open session (shown = main = the working one)

	lines := strings.Split(m.View(), "\n")

	if !strings.HasPrefix(lines[1], "▎") || !strings.HasPrefix(lines[2], "▌") {
		t.Fatalf("open row bar and cursor bar:\n%s", m.View())
	}
}

func TestHeadHasTheMachineAndAClickablePowerGlyph(t *testing.T) {
	m, src := claudeModel(t, 32, 30)

	if !strings.Contains(strings.Split(m.View(), "\n")[0], "lap") {
		t.Fatalf("head:\n%s", m.View())
	}
	tapText(t, m, powerGlyph)

	if m.claude.mode != modePower || len(src.calls) == 0 {
		t.Fatalf("mode=%v calls=%v", m.claude.mode, src.calls)
	}
}

func TestFooterSitsOnOneLineWhenItFitsAndWrapsWhenItDoesNot(t *testing.T) {
	wide, _ := claudeModel(t, 32, 30)
	together := false
	for _, line := range strings.Split(wide.View(), "\n") {
		together = together || (strings.Contains(line, "＋ New") && strings.Contains(line, "Terminals ›") && strings.Contains(line, "History ›"))
	}
	if !together || !strings.Contains(wide.View(), "Stop all 2") {
		t.Fatalf("footer at 32:\n%s", wide.View())
	}
	fits(t, wide)
	narrow, _ := claudeModel(t, 24, 30)
	for _, want := range []string{"Stop all 2", "＋ New", "Terminals ›", "History ›"} {
		if !strings.Contains(narrow.View(), want) {
			t.Errorf("narrow lacks %q:\n%s", want, narrow.View())
		}
	}
	fits(t, narrow)
}

func TestTappingASessionShowsItInTheRightPaneAndFocusesIt(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	src.shown = ""

	tapText(t, m, "19Oct - mytools")

	if got := strings.Join(src.calls, ";"); got != "show lap s2 1 focus" {
		t.Fatalf("calls = %q", got)
	}
	if m.claude.sel != idIdle {
		t.Fatalf("selection = %s", m.claude.sel)
	}
}

func TestASessionOutsideTmuxCannotBeShownButCanBeStopped(t *testing.T) {
	m, src := claudeModel(t, 44, 30)

	tapText(t, m, "24Oct - villa")

	if len(src.calls) != 0 || !strings.Contains(m.View(), "open outside devmesh") {
		t.Fatalf("calls=%v view:\n%s", src.calls, m.View())
	}
	send(m, "x")
	if got := strings.Join(src.calls, ";"); got != "stop lap "+idOutside {
		t.Fatalf("calls = %q", got)
	}
}

func TestRowsHaveNoInlineButtons(t *testing.T) {
	m, _ := claudeModel(t, 44, 30, other("desk", feed.ReachOnline, true, 10))

	if view := m.View(); strings.Contains(view, "[Stop]") || strings.Contains(view, "[Move to") {
		t.Fatalf("the actions live in the status bar header:\n%s", view)
	}
}

func TestHeaderTellsTheStatusBarAboutTheOpenSessionAndClearsWhenNoneIsOpen(t *testing.T) {
	m, src := claudeModel(t, 32, 30, other("desk", feed.ReachOnline, true, 10))

	run(m, m.syncHeader()) // the model built by claudeModel has not run Update since the poll
	if got := strings.Join(src.headers, ";"); got != "lap|27Oct - tools|Stop|Move to desk" {
		t.Fatalf("headers = %q", got)
	}
	src.shown, src.snap.Machines[0].Claude = "", src.snap.Machines[0].Claude[:3] // the open one is stopped
	poll(m, src)
	run(m, m.syncHeader())

	if got := src.headers[len(src.headers)-1]; got != "lap|||" {
		t.Fatalf("headers = %q", src.headers)
	}
}

func TestHeaderOffersAPickerWhenSeveralMachinesCanReceive(t *testing.T) {
	m, src := claudeModel(t, 32, 30, other("a", feed.ReachOnline, true, 10), other("b", feed.ReachOnline, true, 20))

	run(m, m.syncHeader())

	if got := strings.Join(src.headers, ";"); got != "lap|27Oct - tools|Stop|Move to ▾" {
		t.Fatalf("headers = %q", got)
	}
}

func TestStatusBarStopActsOnTheOpenSessionNotOnTheCursorRow(t *testing.T) {
	m, src := claudeModel(t, 32, 30)
	send(m, "down", "down") // the cursor is on another session

	send(m, keyHeaderStop)

	if got := strings.Join(src.calls, ";"); got != "stop lap "+idWorking {
		t.Fatalf("calls = %q (the open session is the working one on main)", got)
	}
}

func TestStatusBarMoveGoesStraightToTheOnlyTargetAndActsOnTheOpenSession(t *testing.T) {
	m, src := claudeModel(t, 32, 30, other("desk", feed.ReachOnline, true, 10))
	send(m, "down")

	send(m, keyHeaderMove)

	if got := strings.Join(src.calls, ";"); got != "move lap "+idWorking+" desk;show desk fresh " {
		t.Fatalf("calls = %q", got)
	}
}

func TestStatusBarMoveOpensThePickerWhenThereIsMoreThanOneTarget(t *testing.T) {
	m, src := claudeModel(t, 32, 30, other("a", feed.ReachOnline, true, 10), other("b", feed.ReachOnline, true, 20))
	send(m, "down")

	send(m, keyHeaderMove)

	if m.claude.mode != modeTargets || m.claude.pending.id != idWorking || len(src.calls) != 0 {
		t.Fatalf("mode=%v pending=%+v calls=%v", m.claude.mode, m.claude.pending, src.calls)
	}
}

func TestStatusBarKeysDoNothingWithoutAnOpenSession(t *testing.T) {
	m, src := claudeModel(t, 32, 30, other("desk", feed.ReachOnline, true, 10))
	src.shown = ""
	m.shown = ""

	send(m, keyHeaderStop, keyHeaderMove)

	if len(src.calls) != 0 || m.claude.mode != modeClaude {
		t.Fatalf("mode=%v calls=%v", m.claude.mode, src.calls)
	}
}

func TestKeyboardStopAndMoveStillActOnTheSelectedRow(t *testing.T) {
	m, src := claudeModel(t, 32, 30, other("desk", feed.ReachOnline, true, 10))
	send(m, "down")

	send(m, "m")

	if got := strings.Join(src.calls, ";"); got != "move lap "+idIdle+" desk;show desk fresh " {
		t.Fatalf("calls = %q", got)
	}
}

func TestALongStatusWordMovesUnderTheNameOnATinyList(t *testing.T) {
	m, _ := claudeModel(t, 20, 30)
	m.claude.machine.Claude[3].Status = feed.ClaudeWaiting

	view := m.View()

	if !strings.Contains(view, "waiting for you") {
		t.Fatalf("view:\n%s", view)
	}
	fits(t, m)
}

func TestMoveListMarksTheBestMachineAndRefusesTheOnesThatCannotReceive(t *testing.T) {
	m, src := claudeModel(t, 44, 30,
		other("big", feed.ReachOnline, true, 900), other("small", feed.ReachOnline, true, 100),
		other("off", feed.ReachOffline, true, 0), other("bare", feed.ReachOnline, false, 0))

	send(m, keyHeaderMove)

	view := m.View()
	for _, want := range []string{"move to…", "small", "★ best", "load 100 MB", "big", "off", "bare", "no Claude"} {
		if !strings.Contains(view, want) {
			t.Errorf("move list lacks %q:\n%s", want, view)
		}
	}
	if strings.Index(view, "small") > strings.Index(view, "big") || strings.Index(view, "big") > strings.Index(view, "bare") {
		t.Fatalf("eligible machines first, lowest load first:\n%s", view)
	}

	tapText(t, m, "bare")
	if len(src.calls) != 0 || !strings.Contains(m.View(), "bare · no Claude") {
		t.Fatalf("calls=%v view:\n%s", src.calls, m.View())
	}
	tapText(t, m, "small")
	if got := strings.Join(src.calls, ";"); got != "move lap "+idWorking+" small;show small fresh " {
		t.Fatalf("calls = %q", got)
	}
	if m.claude.mode != modeClaude {
		t.Fatal("after the move the list is back on the sessions")
	}
}

func TestMovingWithinTheSameMachineWindowFocusesTheShownSession(t *testing.T) {
	m, src := claudeModel(t, 44, 30)

	run(m, m.resumeClaude(idPast, ""))

	if got := strings.Join(src.calls, ";"); got != "resume lap "+idPast+";show lap fresh  focus" {
		t.Fatalf("calls = %q", got)
	}
}

func TestStopAllStopsEverySessionIdleForOverAnHour(t *testing.T) {
	m, src := claudeModel(t, 44, 30)

	tapText(t, m, "Stop all 2")

	if got := strings.Join(src.calls, ";"); got != "stop lap "+idStale+";stop lap "+idOutside {
		t.Fatalf("calls = %q", got)
	}
}

func TestHistoryIsSearchableAndOffersResumeHereOrElsewhere(t *testing.T) {
	m, src := claudeModel(t, 44, 30, other("desk", feed.ReachOnline, true, 10))

	tapText(t, m, "History ›")
	view := m.View()
	for _, want := range []string{"history › lap", "18Oct - form guide", "1 h", "13Oct - document skill", "3 d"} {
		if !strings.Contains(view, want) {
			t.Errorf("history lacks %q:\n%s", want, view)
		}
	}
	typeText(m, "document")
	if strings.Contains(m.View(), "form guide") || !strings.Contains(m.View(), "[Resume on desk]") {
		t.Fatalf("search must filter and the cursor row offers resume:\n%s", m.View())
	}

	tapText(t, m, "[Resume on desk]")

	if got := strings.Join(src.calls, ";"); got != "move lap "+idPastTwo+" desk;show desk fresh " {
		t.Fatalf("calls = %q", got)
	}
}

func TestResumeHereRunsDmAndShowsTheSessionWithFocus(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	send(m, "H")

	tapText(t, m, "[Resume]")

	if got := strings.Join(src.calls, ";"); got != "resume lap "+idPast+";show lap fresh  focus" {
		t.Fatalf("calls = %q", got)
	}
	if m.claude.mode != modeClaude {
		t.Fatal("back to the sessions after resuming")
	}
}

func TestEscLeavesHistoryAndTheBackLineDoesToo(t *testing.T) {
	m, _ := claudeModel(t, 44, 30)
	send(m, "H")
	send(m, "esc")
	if m.claude.mode != modeClaude {
		t.Fatalf("mode = %v", m.claude.mode)
	}
	send(m, "H")
	tapText(t, m, "‹ history")
	if m.claude.mode != modeClaude {
		t.Fatalf("mode = %v", m.claude.mode)
	}
}

func TestNewSessionPrefillsTodayAsksTheProjectAndShowsItWithFocus(t *testing.T) {
	m, src := claudeModel(t, 44, 30)

	tapText(t, m, "＋ New")
	prefix := m.namePrefix()
	if m.claude.mode != modeNew || m.claude.input.Value() != prefix {
		t.Fatalf("mode=%v input=%q want %q", m.claude.mode, m.claude.input.Value(), prefix)
	}
	run(m, m.projectsCmd())
	typeText(m, "api")
	view := m.View()
	for _, want := range []string{"new Claude › lap › project", prefix + "api", "docs"} {
		if !strings.Contains(view, want) {
			t.Errorf("new screen lacks %q:\n%s", want, view)
		}
	}

	tapText(t, m, "docs")

	if got := strings.Join(src.calls, ";"); got != "new lap "+prefix+"api docs;show lap fresh  focus" {
		t.Fatalf("calls = %q", got)
	}
}

func TestNewSessionIsRefusedWhenTheMachineHasNoClaude(t *testing.T) {
	m, _ := claudeModel(t, 44, 30)
	m.claude.machine.HasClaude = false
	m.claude.machine.ClaudeKnown = true

	send(m, "n")

	if m.claude.mode != modeClaude || !strings.Contains(m.View(), "Claude is not installed") {
		t.Fatalf("mode=%v view:\n%s", m.claude.mode, m.View())
	}
}

func TestTerminalsFooterShowsTheOldListAndTheBackButtonReturns(t *testing.T) {
	m, src := claudeModel(t, 44, 30)

	tapText(t, m, "Terminals ›")
	if m.claude.mode != modeTerminals || !strings.Contains(m.View(), ">_ main") || !strings.Contains(m.View(), "+ New") {
		t.Fatalf("terminal list:\n%s", m.View())
	}
	src.calls = nil
	tapAt(m, m.buttons()[0].from, 1)

	if m.claude.mode != modeClaude || len(src.calls) != 0 {
		t.Fatalf("mode=%v calls=%v", m.claude.mode, src.calls)
	}
}

func TestOnTheClaudeHomeWithNothingOpenTheRightPaneIsThePlaceholderNotATerminal(t *testing.T) {
	machine := claudeMachine()
	machine.Claude = machine.Claude[:3] // main no longer runs Claude
	src := &fakeSource{snap: feed.Snapshot{Machines: []feed.Machine{machine}}, shown: ""}
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback()})
	m.width, m.height = 44, 30

	poll(m, src)
	poll(m, src)

	if got := strings.Join(src.calls, ";"); got != "hold lap choose" {
		t.Fatalf("calls = %q (one placeholder, no terminal)", got)
	}
}

func TestAClaudeSessionStoppedWhileShownGivesWayToThePlaceholder(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	src.snap.Machines[0].Claude = src.snap.Machines[0].Claude[:3]

	poll(m, src)

	if got := strings.Join(src.calls, ";"); got != "hold lap choose" || m.shown != "" {
		t.Fatalf("calls = %q shown = %q", got, m.shown)
	}
}

func TestATerminalLeftOverFromTheTerminalsScreenIsReplacedWhenBackOnTheHome(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	src.snap.Machines[0].Claude = src.snap.Machines[0].Claude[:3]
	src.shown = "main"
	tapText(t, m, "Terminals ›")
	poll(m, src)
	src.calls = nil

	tapAt(m, m.buttons()[0].from, 1) // ‹ back

	if got := strings.Join(src.calls, ";"); got != "hold lap choose" {
		t.Fatalf("calls = %q", got)
	}
}

func TestEnteringTheTerminalsScreenWithNothingOpenShowsTheMainTerminal(t *testing.T) {
	machine := claudeMachine()
	machine.Claude = machine.Claude[:3]
	src := &fakeSource{snap: feed.Snapshot{Machines: []feed.Machine{machine}}, shown: ""}
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback()})
	m.width, m.height = 44, 30
	poll(m, src)
	src.calls = nil

	tapText(t, m, "Terminals ›")

	if got := strings.Join(src.calls, ";"); got != "show lap main 2" {
		t.Fatalf("calls = %q", got)
	}
}

func TestAPollRacingAFreshlyShownSessionDoesNotReplaceIt(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	src.shown = ""
	tapText(t, m, "19Oct - mytools")
	src.calls = nil

	poll(m, src) // reads tmux before the show landed

	if len(src.calls) != 0 || m.shown != "s2" {
		t.Fatalf("calls=%v shown=%q", src.calls, m.shown)
	}
}

func TestEveryClaudeScreenFitsNarrowAndWideLists(t *testing.T) {
	for _, width := range []int{24, 32, 40, 60} {
		m, _ := claudeModel(t, width, 14, other("a", feed.ReachOnline, true, 5), other("b", feed.ReachOffline, true, 0))
		fits(t, m)
		if got := len(strings.Split(m.View(), "\n")); got > 14 {
			t.Fatalf("width %d: %d lines for 14", width, got)
		}
		for _, name := range []string{"H", "esc", "n", "esc", "t", "esc", "m"} {
			send(m, name)
			fits(t, m)
		}
	}
}

func TestKeysMoveTheCursorAndEnterShowsTheSession(t *testing.T) {
	m, src := claudeModel(t, 44, 30)

	send(m, "down", "enter")

	if m.claude.sel != idIdle || strings.Join(src.calls, ";") != "show lap s2 1 focus" {
		t.Fatalf("sel=%s calls=%v", m.claude.sel, src.calls)
	}
	send(m, "x")
	if got := src.calls[len(src.calls)-1]; got != "stop lap "+idIdle {
		t.Fatalf("calls = %v", src.calls)
	}
}

func TestAFailedActionShowsOnTheLastLineAndKeepsTheSessions(t *testing.T) {
	m, _ := claudeModel(t, 44, 30)

	m.Update(claudeDoneMsg{err: fmt.Errorf("boom")})

	if !strings.Contains(m.View(), "boom") || m.claude.busy {
		t.Fatalf("view:\n%s", m.View())
	}
}

func TestAutoPickNeverShowsAClaudeSession(t *testing.T) {
	machine := claudeMachine()
	machine.Terminals = []feed.Terminal{term("s2", "1", ""), term("s3", "4", "")}
	src := &fakeSource{snap: feed.Snapshot{Machines: []feed.Machine{machine}}, shown: ""}
	m := New(Options{Host: "lap", Source: src, Catalog: i18n.Fallback()})
	m.width, m.height = testWidth, 30
	poll(m, src)
	for _, call := range src.calls {
		if strings.HasPrefix(call, "show ") {
			t.Fatalf("auto-pick showed a Claude session: %q", call)
		}
	}
}

func TestChoosingASessionPutsItsTitleInTheStatusBar(t *testing.T) {
	m, src := claudeModel(t, 32, 30)
	src.shown = ""
	m.shown = ""

	tapText(t, m, "19Oct - mytools")

	if len(src.headers) == 0 || src.headers[len(src.headers)-1] != "lap|19Oct - mytools|Stop|" {
		t.Fatalf("headers = %q", src.headers)
	}
}
