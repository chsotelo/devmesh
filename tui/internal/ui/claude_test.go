package ui

import (
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

const (
	sidWorking = "00000000-0000-4000-8000-000000000001"
	sidIdle    = "00000000-0000-4000-8000-000000000002"
	sidStale   = "00000000-0000-4000-8000-000000000003"
	sidWaiting = "00000000-0000-4000-8000-000000000004"
	sidOutside = "00000000-0000-4000-8000-000000000005"
	sidLaptop  = "00000000-0000-4000-8000-000000000006"
	sidPast    = "00000000-0000-4000-8000-000000000007"
	sidPastTwo = "00000000-0000-4000-8000-000000000008"
)

// claudeSnapshot is a mesh with sessions: "mac" holds five of every state, "laptop" one,
// "desk" is off. extra adds that many idle machines with Claude (to force the picker).
func claudeSnapshot(extra int) feed.Snapshot {
	live := func(id string, status feed.ClaudeStatus, idle int64, tmux string, mb int, name string) feed.ClaudeSession {
		return feed.ClaudeSession{Machine: "mac", ID: id, Status: status, IdleSecs: idle, Tmux: tmux, RSSMB: mb, Cwd: "/home/u/PROJECTS/x", Name: name}
	}
	snap := feed.Snapshot{Device: "tablet", Version: "0.9.0", Machines: []feed.Machine{
		{Name: "mac", Reach: feed.ReachOnline, Color: 33, HasClaude: true,
			Terminals: []feed.Terminal{{Host: "mac", Session: "main", Window: "2", Active: true}},
			Claude: []feed.ClaudeSession{
				live(sidStale, feed.ClaudeIdle, 273*60, "s3:@1.%0", 67, "26Oct - calendario"),
				live(sidOutside, feed.ClaudeIdle, 3*86400, "", 14, "24Oct - villa"),
				live(sidIdle, feed.ClaudeIdle, 20*60, "s2:@1.%0", 62, "19Oct - mytools"),
				live(sidWaiting, feed.ClaudeWaiting, 10, "s4:@1.%0", 40, "20Oct - embeddings"),
				live(sidWorking, feed.ClaudeWorking, 4, "main:@2.%1", 262, "27Oct - tools"),
			},
			History: []feed.ClaudeHistory{
				{Machine: "mac", ID: sidPast, AgeSecs: 3600, Cwd: "/home/u/PROJECTS/x", Name: "18Oct - form guide"},
				{Machine: "mac", ID: sidPastTwo, AgeSecs: 3 * 86400, Cwd: "/home/u/PROJECTS/y", Name: "13Oct - document skill"},
			}},
		{Name: "laptop", Reach: feed.ReachOnline, Color: 40, HasClaude: true, Claude: []feed.ClaudeSession{
			{Machine: "laptop", ID: sidLaptop, Status: feed.ClaudeIdle, IdleSecs: 120, Tmux: "lap:@1.%0", RSSMB: 40, Cwd: "/home/u/PROJECTS/x", Name: "21Oct - laptop work"},
		}},
		{Name: "desk", Reach: feed.ReachOffline, Color: 99},
	}}
	for i := range extra {
		snap.Machines = append(snap.Machines, feed.Machine{Name: fmt.Sprintf("box%d", i), Reach: feed.ReachOnline, Color: 50, HasClaude: true})
	}
	return snap
}

// newClaudeModel is a model on the Claude home with that mesh, viewing "mac".
func newClaudeModel(t *testing.T, width, height int, snap feed.Snapshot) (*Model, *fakeSource) {
	t.Helper()
	m, fake := newTestModel(t, width, height, true)
	fake.snapshot = snap
	fake.projects = []string{"api", "docs"}
	m.Update(feedMsg{seq: m.feedSeq, snap: snap})
	m.inflight = map[string]int{}
	m.claudeHost = "mac"
	m.resolveClaude()
	return m, fake
}

func indexOfText(text, needle string) int { return strings.Index(text, needle) }

func TestHomeListsSessionsWorkingFirstThenWaitingThenIdleByIdleTime(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	text := m.View()

	order := []string{"27Oct - tools", "20Oct - embeddings", "19Oct - mytools", "26Oct - calendario", "24Oct - villa"}
	last := -1
	for _, name := range order {
		at := indexOfText(text, name)
		if at < 0 || at <= last {
			t.Fatalf("%q is out of order (at %d, previous %d):\n%s", name, at, last, text)
		}
		last = at
	}
	for _, want := range []string{"working", "waiting for you", "20 min", "4 h", "3 d"} {
		if !strings.Contains(text, want) {
			t.Errorf("home lacks the word %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "21Oct - laptop work") {
		t.Fatal("only the sessions of the viewed machine are listed")
	}
}

func TestHomeShowsTheStaleLineOnlyWhenSomethingSitsIdleOverAnHour(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	text := m.View()
	for _, want := range []string{"2 idle for over 1 h", "Stop all 2"} {
		if !strings.Contains(text, want) {
			t.Errorf("home lacks %q:\n%s", want, text)
		}
	}

	snap := claudeSnapshot(0)
	snap.Machines[0].Claude = snap.Machines[0].Claude[2:]
	m.Update(feedMsg{seq: m.feedSeq, snap: snap})
	if strings.Contains(m.View(), "idle for over 1 h") {
		t.Fatal("no stale line without stale sessions")
	}
}

func TestHomeFooterOffersNewTerminalsAndHistoryWithItsCount(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	text := m.View()

	for _, want := range []string{"＋ New", "Terminals ›", "History (2) ›"} {
		if !strings.Contains(text, want) {
			t.Errorf("footer lacks %q:\n%s", want, text)
		}
	}
	hitFor(t, m, intent{verb: verbNew})
	hitFor(t, m, intent{verb: verbTerminals})
	hitFor(t, m, intent{verb: verbHistory})
}

func TestMachinesAreTabsWhenFewAndTappingOneShowsItsSessions(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	first := strings.Split(m.View(), "\n")[1]
	for _, want := range []string{"mac", "laptop", "desk"} {
		if !strings.Contains(first, want) {
			t.Fatalf("tabs lack %q: %q", want, first)
		}
	}

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbViewMachine, arg: "laptop"})))

	text := m.View()
	if !strings.Contains(text, "21Oct - laptop work") || strings.Contains(text, "27Oct - tools") {
		t.Fatalf("laptop tab shows the wrong sessions:\n%s", text)
	}
	if m.claudeSel != sidLaptop {
		t.Fatalf("selection = %s", m.claudeSel)
	}
}

func TestOfflineMachineTabExplainsItself(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	m.applyIntent(intent{verb: verbViewMachine, arg: "desk"})

	if !strings.Contains(m.View(), "off or unreachable") {
		t.Fatalf("offline machine says nothing:\n%s", m.View())
	}
}

func TestManyMachinesUseASearchablePicker(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(3))
	if !strings.Contains(strings.Split(m.View(), "\n")[1], "mac ▾") {
		t.Fatalf("picker missing:\n%s", m.View())
	}

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbPickMachine})))
	if m.top().screen != screenPick {
		t.Fatalf("route = %+v", m.top())
	}
	typeText(m, "box1")
	items := m.menuItems()
	if len(items) != 1 || items[0].label != "box1" {
		t.Fatalf("search items = %+v", items)
	}
	drain(t, m, press(m, "enter"))

	if m.top().screen != screenHome || m.claudeHost != "box1" {
		t.Fatalf("route=%+v host=%s", m.top(), m.claudeHost)
	}
}

func TestTapSelectsAndTapAgainOpensTheSessionOnAWideScreen(t *testing.T) {
	m, fake := newClaudeModel(t, 160, 45, claudeSnapshot(0))
	if m.claudeSel != sidWorking {
		t.Fatalf("the working session starts selected, got %s", m.claudeSel)
	}

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbSelect, arg: claudeKey(sidIdle)})))
	if len(fake.opened) != 0 || m.claudeSel != sidIdle {
		t.Fatalf("first tap only selects: opened=%v sel=%s", fake.opened, m.claudeSel)
	}
	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbSelect, arg: claudeKey(sidIdle)})))

	if len(fake.opened) != 1 || fake.opened[0] != "mac/s2/" {
		t.Fatalf("opened = %v", fake.opened)
	}
}

func TestWideScreenShowsThePaneWithHeaderActionsAndTheLiveScreen(t *testing.T) {
	m, fake := newClaudeModel(t, 160, 45, claudeSnapshot(0))
	fake.screens["mac/main/2"] = []string{"claude says hello"}
	m.shots["mac/main/2"] = shot{lines: fake.screens["mac/main/2"], at: fixedNow}

	text := m.View()

	assertFits(t, m, 160, 45)
	for _, want := range []string{"[open]", "[Stop]", "[Move to ▾]", "claude says hello", "live screen"} {
		if !strings.Contains(text, want) {
			t.Errorf("pane lacks %q:\n%s", want, text)
		}
	}
	if got := m.visibleTerminals(); len(got) != 1 || got[0].Key() != "mac/main/2" {
		t.Fatalf("the pane reads the screen of the selected session: %+v", got)
	}
}

func TestNarrowTapOpensTheFullScreenSessionAndBackReturns(t *testing.T) {
	m, fake := newClaudeModel(t, 40, 30, claudeSnapshot(0))
	assertFits(t, m, 40, 30)

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbSelect, arg: claudeKey(sidIdle)})))
	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbSelect, arg: claudeKey(sidIdle)})))

	if m.top().screen != screenSession || m.top().arg != sidIdle {
		t.Fatalf("route = %+v", m.top())
	}
	assertFits(t, m, 40, 30)
	text := m.View()
	for _, want := range []string{"19Oct - mytools", "[open]", "[Stop]", "‹ back"} {
		if !strings.Contains(text, want) {
			t.Errorf("session screen lacks %q:\n%s", want, text)
		}
	}
	drain(t, m, press(m, "o"))
	if len(fake.opened) != 1 || fake.opened[0] != "mac/s2/" {
		t.Fatalf("opened = %v", fake.opened)
	}
	press(m, "esc")
	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestSessionOutsideTmuxCannotBeOpenedButCanBeStopped(t *testing.T) {
	m, fake := newClaudeModel(t, 160, 45, claudeSnapshot(0))
	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbSelect, arg: claudeKey(sidOutside)})))

	text := m.View()
	if !strings.Contains(text, "open outside devmesh") || strings.Contains(text, "[open]") || !strings.Contains(text, "[Stop]") {
		t.Fatalf("outside session pane:\n%s", text)
	}
	drain(t, m, press(m, "enter"))
	if len(fake.opened) != 0 {
		t.Fatalf("opened = %v", fake.opened)
	}
	if notice, _ := m.activeNotice(); notice != "open outside devmesh" {
		t.Fatalf("notice = %q", notice)
	}

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbStop, arg: sidOutside})))

	if got := strings.Join(fake.claudeCalls, ","); got != "stop|mac|"+sidOutside {
		t.Fatalf("calls = %s", got)
	}
}

func TestStopCallsTheSourceAndGoesBackHome(t *testing.T) {
	m, fake := newClaudeModel(t, 40, 30, claudeSnapshot(0))
	m.applyIntent(intent{verb: verbSelect, arg: claudeKey(sidIdle)})
	m.applyIntent(intent{verb: verbSelect, arg: claudeKey(sidIdle)})

	drain(t, m, press(m, "x"))

	if got := strings.Join(fake.claudeCalls, ","); got != "stop|mac|"+sidIdle {
		t.Fatalf("calls = %s", got)
	}
	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestStopAllStopsEverySessionIdleForOverAnHour(t *testing.T) {
	m, fake := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbStopIdle})))

	got := strings.Join(fake.claudeCalls, ",")
	want := "stop|mac|" + sidStale + ",stop|mac|" + sidOutside
	if got != want {
		t.Fatalf("calls = %s, want %s", got, want)
	}
}

func TestAFailedStopIsReportedAndNothingElseHappens(t *testing.T) {
	m, fake := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	fake.claudeErr = errFeedDown

	drain(t, m, press(m, "x"))

	if notice, isError := m.activeNotice(); !isError || !strings.Contains(notice, "hub unreachable") {
		t.Fatalf("notice = %q", notice)
	}
	if m.claudeBusy {
		t.Fatal("the panel must accept actions again")
	}
}

func TestMoveWithOneOtherMachineIsADirectButton(t *testing.T) {
	snap := claudeSnapshot(0)
	snap.Machines = snap.Machines[:2]
	m, fake := newClaudeModel(t, 160, 45, snap)
	fake.claudeSession = "moved-session"
	if !strings.Contains(m.View(), "[Move to laptop]") {
		t.Fatalf("direct move button missing:\n%s", m.View())
	}

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbMoveTo, arg: sidWorking, extra: "laptop"})))

	if got := strings.Join(fake.claudeCalls, ","); got != "move|mac|"+sidWorking+"|laptop" {
		t.Fatalf("calls = %s", got)
	}
	if len(fake.opened) != 1 || fake.opened[0] != "laptop/moved-session/" || m.claudeHost != "laptop" {
		t.Fatalf("opened=%v host=%s", fake.opened, m.claudeHost)
	}
}

func TestMoveListMarksTheBestMachineAndDisablesTheOnesThatCannotReceive(t *testing.T) {
	snap := claudeSnapshot(1)
	m, fake := newClaudeModel(t, 100, 40, snap)
	fake.claudeSession = "moved"

	drain(t, m, press(m, "m"))

	if m.top().screen != screenMove {
		t.Fatalf("route = %+v", m.top())
	}
	text := m.View()
	for _, want := range []string{"box0", "★ best", "laptop", "load 40 MB", "desk", "off"} {
		if !strings.Contains(text, want) {
			t.Errorf("move list lacks %q:\n%s", want, text)
		}
	}
	labels := []string{}
	for _, item := range m.menuItems() {
		labels = append(labels, item.label)
	}
	if strings.Join(labels, ",") != "box0,laptop,desk" {
		t.Fatalf("order = %v (eligible first, lowest load first, disabled last)", labels)
	}
	if !strings.Contains(m.menuItems()[0].hint, "★ best") || strings.Contains(m.menuItems()[1].hint, "★") {
		t.Fatalf("only the best one is starred: %+v", m.menuItems())
	}

	press(m, "down", "down", "enter")
	if len(fake.claudeCalls) != 0 {
		t.Fatalf("a disabled machine must not move anything: %v", fake.claudeCalls)
	}
	if notice, _ := m.activeNotice(); notice != "desk · off" {
		t.Fatalf("reason = %q", notice)
	}

	press(m, "up", "up")
	drain(t, m, press(m, "enter"))
	if got := strings.Join(fake.claudeCalls, ","); got != "move|mac|"+sidWorking+"|box0" {
		t.Fatalf("calls = %s", got)
	}
	if m.top().screen != screenHome || m.claudeHost != "box0" {
		t.Fatalf("route=%+v host=%s", m.top(), m.claudeHost)
	}
}

func TestHistoryListsStoppedSessionsAndSearchFiltersThem(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbHistory})))

	text := m.View()
	for _, want := range []string{"history › mac", "18Oct - form guide", "1 h", "13Oct - document skill", "3 d"} {
		if !strings.Contains(text, want) {
			t.Errorf("history lacks %q:\n%s", want, text)
		}
	}
	typeText(m, "document")
	items := m.menuItems()
	if len(items) != 1 || items[0].label != "13Oct - document skill" {
		t.Fatalf("filtered = %+v", items)
	}
	typeText(m, "zzz")
	if !strings.Contains(m.View(), "no stopped sessions") {
		t.Fatalf("empty search says nothing:\n%s", m.View())
	}
}

func TestResumeOffersTheSameMachineAndEveryOtherOne(t *testing.T) {
	m, fake := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	fake.claudeSession = "back-again"
	drain(t, m, press(m, "H"))
	drain(t, m, press(m, "enter"))

	if m.top().screen != screenHistoryItem || m.top().arg != sidPast {
		t.Fatalf("route = %+v", m.top())
	}
	text := m.View()
	for _, want := range []string{"18Oct - form guide", "Resume", "Resume on laptop", "★ best", "Resume on desk", "off"} {
		if !strings.Contains(text, want) {
			t.Errorf("resume menu lacks %q:\n%s", want, text)
		}
	}

	drain(t, m, press(m, "enter"))

	if got := strings.Join(fake.claudeCalls, ","); got != "resume|mac|"+sidPast {
		t.Fatalf("calls = %s", got)
	}
	if len(fake.opened) != 1 || fake.opened[0] != "mac/back-again/" || m.top().screen != screenHome {
		t.Fatalf("opened=%v route=%+v", fake.opened, m.top())
	}
}

func TestResumeOnAnotherMachineMovesTheSession(t *testing.T) {
	m, fake := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	fake.claudeSession = "there"
	drain(t, m, press(m, "H"))
	drain(t, m, press(m, "enter"))

	drain(t, m, press(m, "down", "enter"))

	if got := strings.Join(fake.claudeCalls, ","); got != "move|mac|"+sidPast+"|laptop" {
		t.Fatalf("calls = %s", got)
	}
	if len(fake.opened) != 1 || fake.opened[0] != "laptop/there/" {
		t.Fatalf("opened = %v", fake.opened)
	}
}

func TestNewSessionAsksNamePrefilledWithTodayThenTheProject(t *testing.T) {
	m, fake := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	fake.claudeSession = "fresh"

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbNew})))

	if m.top().screen != screenClaudeNew || m.top().arg != "mac" {
		t.Fatalf("route = %+v", m.top())
	}
	prefix := fmt.Sprintf("%02d%s - ", fixedNow.Day(), fixedNow.Month().String()[:3])
	if m.input.Value() != prefix {
		t.Fatalf("name = %q, want %q", m.input.Value(), prefix)
	}
	typeText(m, "api work")
	text := m.View()
	for _, want := range []string{"new Claude › mac › project", "api", "docs", prefix + "api work"} {
		if !strings.Contains(text, want) {
			t.Errorf("new screen lacks %q:\n%s", want, text)
		}
	}

	drain(t, m, press(m, "down", "enter"))

	want := "new|mac|" + prefix + "api work|docs"
	if got := strings.Join(fake.claudeCalls, ","); got != want {
		t.Fatalf("calls = %s, want %s", got, want)
	}
	if len(fake.opened) != 1 || fake.opened[0] != "mac/fresh/" || m.top().screen != screenHome {
		t.Fatalf("opened=%v route=%+v", fake.opened, m.top())
	}
}

func TestNewSessionRefusesAnEmptyNameAndAnOfflineMachine(t *testing.T) {
	m, fake := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	drain(t, m, press(m, "n"))
	m.input.SetValue("   ")

	press(m, "enter")

	if notice, _ := m.activeNotice(); notice != "type the session name" || len(fake.claudeCalls) != 0 {
		t.Fatalf("notice=%q calls=%v", notice, fake.claudeCalls)
	}
	press(m, "esc")
	m.applyIntent(intent{verb: verbViewMachine, arg: "desk"})
	press(m, "n")
	if m.top().screen != screenHome {
		t.Fatalf("an offline machine cannot start sessions: %+v", m.top())
	}
}

func TestTerminalsScreenIsReachableFromTheFooterAndBack(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	drain(t, m, tapOn(m, hitFor(t, m, intent{verb: verbTerminals})))
	if m.top().screen != screenTerminals {
		t.Fatalf("route = %+v", m.top())
	}
	hitFor(t, m, intent{verb: verbNewOn, arg: "mac"})
	press(m, "esc")

	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestKeysMoveBetweenSessionsAndMachines(t *testing.T) {
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))

	press(m, "down")
	if m.claudeSel != sidWaiting {
		t.Fatalf("down selects the next row, got %s", m.claudeSel)
	}
	press(m, "right")
	if m.claudeHost != "laptop" || m.claudeSel != sidLaptop {
		t.Fatalf("right shows the next machine: %s %s", m.claudeHost, m.claudeSel)
	}
	press(m, "left", "end")
	if m.claudeHost != "mac" || m.claudeSel != sidOutside {
		t.Fatalf("host=%s sel=%s", m.claudeHost, m.claudeSel)
	}
}

func TestVanishedSessionLeavesItsFullScreen(t *testing.T) {
	m, _ := newClaudeModel(t, 40, 30, claudeSnapshot(0))
	m.applyIntent(intent{verb: verbSelect, arg: claudeKey(sidIdle)})
	m.applyIntent(intent{verb: verbSelect, arg: claudeKey(sidIdle)})
	snap := claudeSnapshot(0)
	snap.Machines[0].Claude = snap.Machines[0].Claude[:1]

	m.Update(feedMsg{seq: m.feedSeq, snap: snap})

	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestSpanishCatalogReadsTheWordsOfTheDesign(t *testing.T) {
	spanish := i18n.Parse("M_CL_WORKING=trabajando\nM_CL_WAITING=te espera\nM_CL_NEW=＋ Nueva\nM_CL_HISTORY=Historial (%s) ›\nM_CL_STOP=Detener\nM_CL_STALE=%s sin usar hace más de 1 h\nM_CL_STOP_ALL=Detener las %s\n").WithFallback()
	m, _ := newClaudeModel(t, 100, 40, claudeSnapshot(0))
	m.cat = spanish

	text := m.View()

	for _, want := range []string{"trabajando", "te espera", "＋ Nueva", "Historial (2) ›", "2 sin usar hace más de 1 h", "Detener las 2"} {
		if !strings.Contains(text, want) {
			t.Errorf("Spanish home lacks %q:\n%s", want, text)
		}
	}
}

func TestEveryClaudeScreenFitsPhoneAndTabletSizes(t *testing.T) {
	for _, size := range [][2]int{{40, 24}, {40, 12}, {100, 30}, {160, 45}} {
		m, _ := newClaudeModel(t, size[0], size[1], claudeSnapshot(3))
		assertFits(t, m, size[0], size[1])
		for _, key := range []string{"m", "esc", "H", "esc", "n", "esc", "t", "esc"} {
			press(m, key)
			assertFits(t, m, size[0], size[1])
		}
	}
}

func TestWheelScrollsALongSessionList(t *testing.T) {
	snap := claudeSnapshot(0)
	for i := range 12 {
		snap.Machines[0].Claude = append(snap.Machines[0].Claude, feed.ClaudeSession{
			Machine: "mac", ID: fmt.Sprintf("00000000-0000-4000-8000-0000000001%02d", i), Status: feed.ClaudeIdle,
			IdleSecs: int64(60 + i), Tmux: "x:@1.%0", Name: fmt.Sprintf("extra %02d", i),
		})
	}
	m, _ := newClaudeModel(t, 40, 20, snap)
	if strings.Contains(m.View(), "extra 11") {
		t.Fatal("the last row cannot fit yet")
	}

	for range 10 {
		m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelDown, Action: tea.MouseActionPress})
	}

	if !strings.Contains(m.View(), "extra 11") {
		t.Fatalf("the wheel did not scroll:\n%s", m.View())
	}
}

func TestFooterFitsAPhoneWithoutCuttingALabelAndTapsHitEachDestination(t *testing.T) {
	m, _ := newClaudeModel(t, 40, 24, claudeSnapshot(0))

	text := m.View()

	for _, want := range []string{"＋ New", "Terminals ›", "History (2) ›", "Stop all 2"} {
		if !strings.Contains(text, want) || strings.Contains(text, want+"…") {
			t.Errorf("footer cut %q:\n%s", want, text)
		}
	}
	found := map[verb]bool{}
	for _, h := range m.frame().hits {
		if h.area.h != footerHeight {
			continue
		}
		found[h.act.verb] = true
		if h.area.x < 0 || h.area.x+h.area.w > 40 {
			t.Errorf("footer hit %+v is off the screen", h)
		}
	}
	if !found[verbNew] || !found[verbTerminals] || !found[verbHistory] {
		t.Errorf("footer hits = %v", found)
	}
}
