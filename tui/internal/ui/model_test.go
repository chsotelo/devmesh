package ui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

func TestEscOnHomeWithoutFilterQuits(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)

	msgs := drain(t, m, press(m, "esc"))

	if !wasQuit(msgs) || !m.Finished() {
		t.Fatalf("esc on a plain home screen must quit (msgs=%v)", msgs)
	}
}

func TestEscClearsTheFilterBeforeQuitting(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	press(m, "/")
	typeText(m, "api")

	first := drain(t, m, press(m, "esc"))

	if wasQuit(first) || m.Finished() {
		t.Fatal("the first esc only clears the filter")
	}
	if m.filter.Value() != "" || m.filterOn {
		t.Fatalf("filter not cleared: %q on=%v", m.filter.Value(), m.filterOn)
	}
	if second := drain(t, m, press(m, "esc")); !wasQuit(second) {
		t.Fatal("the second esc quits")
	}
}

func TestLetterQTypesIntoTheFilterInsteadOfQuitting(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	press(m, "/")

	msgs := drain(t, m, press(m, "q"))

	if wasQuit(msgs) || m.filter.Value() != "q" {
		t.Fatalf("q inside the filter must be text (value=%q)", m.filter.Value())
	}
}

func TestCtrlCQuitsFromAnywhere(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	press(m, "a")
	typeText(m, "typing")

	msgs := drain(t, m, press(m, "ctrl+c"))

	if !wasQuit(msgs) {
		t.Fatal("ctrl+c must quit even while typing")
	}
}

func TestQuitKeyQuitsFromTheGrid(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)

	if !wasQuit(drain(t, m, press(m, "q"))) {
		t.Fatal("q must quit")
	}
}

func TestArrowsWalkTheGridByGeometry(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)
	if m.selected != "t:laptop/api/1" {
		t.Fatalf("the first terminal starts selected, got %q", m.selected)
	}

	press(m, "right")
	if m.selected != "t:laptop/web/1" {
		t.Fatalf("right -> %q", m.selected)
	}
	press(m, "down")
	if m.selected != "t:laptop/docs/1" {
		t.Fatalf("down from the right column -> %q", m.selected)
	}
	press(m, "down")
	if m.selected != machineKey("desktop") {
		t.Fatalf("down from the last row -> %q", m.selected)
	}
	press(m, "up", "up")
	if m.selected != "t:laptop/api/1" && m.selected != "t:laptop/web/1" {
		t.Fatalf("up twice -> %q", m.selected)
	}
}

func TestEnterOnAMachineOpensItsMenuAndEscGoesBack(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)
	press(m, "up")
	if m.selected != machineKey("laptop") {
		t.Fatalf("up from the first card -> %q", m.selected)
	}

	press(m, "enter")
	if got := m.top(); got.screen != screenMachine || got.arg != "laptop" {
		t.Fatalf("route = %+v", got)
	}
	text := m.View()
	for _, want := range []string{"Open its main terminal", "New terminal here", "Send it a file", "Open its web", "‹ back"} {
		if !strings.Contains(text, want) {
			t.Errorf("machine menu lacks %q:\n%s", want, text)
		}
	}

	press(m, "esc")
	if m.top().screen != screenHome {
		t.Fatalf("esc must go back to home, on %+v", m.top())
	}
}

func TestEnterOnAnOfflineMachineAsksDmToWakeIt(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)
	m.selected = machineKey("desktop")

	cmd := press(m, "enter")

	if cmd == nil || m.lastIntent.verb != verbActivate {
		t.Fatalf("cmd=%v intent=%+v", cmd, m.lastIntent)
	}
	if m.top().screen != screenHome {
		t.Fatal("waking must not leave the home screen")
	}
}

func TestEnterOnANarrowScreenOpensTheDetailAndOKeyOpensTheTerminal(t *testing.T) {
	m, fake := newTestModel(t, 45, 30, true)

	press(m, "enter")
	if got := m.top(); got.screen != screenDetail || got.arg != "laptop/api/1" {
		t.Fatalf("route = %+v", got)
	}
	text := m.View()
	for _, want := range []string{"[open]", "[send file]", "[web]", "live screen", "‹ back"} {
		if !strings.Contains(text, want) {
			t.Errorf("detail lacks %q:\n%s", want, text)
		}
	}

	drain(t, m, press(m, "o"))
	if len(fake.opened) != 1 || fake.opened[0] != "laptop/api/1" {
		t.Fatalf("opened = %v", fake.opened)
	}
	if m.top().screen != screenHome {
		t.Fatal("after opening a terminal the panel returns home")
	}
}

func TestEnterOnAWideScreenOpensTheTerminalDirectly(t *testing.T) {
	m, fake := newTestModel(t, 160, 45, true)

	drain(t, m, press(m, "enter"))

	if len(fake.opened) != 1 || fake.opened[0] != "laptop/api/1" {
		t.Fatalf("opened = %v", fake.opened)
	}
	if m.top().screen != screenHome {
		t.Fatal("the panel stays on home")
	}
}

func TestOutsideTmuxOpeningRunsTheFullScreenCommand(t *testing.T) {
	m, fake := newTestModel(t, 160, 45, false)

	cmd := press(m, "enter")

	if cmd == nil {
		t.Fatal("expected an ExecProcess command")
	}
	if len(fake.opened) != 0 {
		t.Fatal("outside tmux nothing may be opened in the background")
	}
}

func TestDetailClosesWhenItsTerminalDisappears(t *testing.T) {
	m, fake := newTestModel(t, 45, 30, true)
	press(m, "enter")
	gone := sampleSnapshot()
	gone.Machines[0].Terminals = gone.Machines[0].Terminals[1:]
	fake.snapshot = gone

	m.Update(feedMsg{seq: m.feedSeq, snap: gone})

	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestStaleFeedReadingsAreDropped(t *testing.T) {
	m, fake := newTestModel(t, 70, 40, true)
	m.feedSeq = 5
	empty := feed.Snapshot{Device: "ghost"}

	m.Update(feedMsg{seq: 4, snap: empty})
	if m.snap.Device != "tablet" {
		t.Fatal("an answer to an older request must be dropped")
	}
	m.Update(feedMsg{seq: 5, snap: fake.snapshot})
	if m.snap.Device != "tablet" || !m.loaded {
		t.Fatal("the current answer must be applied")
	}
	m.feedBusy = true
	m.Update(feedMsg{seq: 5, err: errFeedDown})
	if m.feedBusy || m.snap.Device != "tablet" || m.feedErr == "" {
		t.Fatal("a failed reading keeps the last good data and clears the busy flag")
	}
}

func TestForcedRefreshInvalidatesTheReadingInFlight(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	m.fetchFeed()
	stale := m.feedSeq

	m.fetchFeed()
	m.Update(feedMsg{seq: stale, snap: feed.Snapshot{Device: "old"}})

	if m.snap.Device == "old" {
		t.Fatalf("the reading of request %d must not win over request %d", stale, m.feedSeq)
	}
}

func TestFeedTickDoesNotStackRequests(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	before := m.feedSeq

	m.feedBusy = true
	m.onFeedTick()
	if m.feedSeq != before {
		t.Fatal("no new request while one is in flight")
	}
	m.feedBusy = false
	m.onFeedTick()
	if m.feedSeq != before+1 || !m.feedBusy {
		t.Fatal("an idle tick starts a request")
	}
}

func TestStaleScreenReadingsAreDropped(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	m.inflight["laptop/api/1"] = 7

	m.applyShot(shotMsg{key: "laptop/api/1", id: 6, lines: []string{"old"}})
	if got := m.shots["laptop/api/1"].lines[0]; got == "old" {
		t.Fatal("an answer to an older capture must be dropped")
	}
	m.applyShot(shotMsg{key: "laptop/api/1", id: 7, lines: []string{"new"}})
	if got := m.shots["laptop/api/1"].lines[0]; got != "new" {
		t.Fatalf("lines = %q", m.shots["laptop/api/1"].lines)
	}
	if _, busy := m.inflight["laptop/api/1"]; busy {
		t.Fatal("the request must be forgotten once answered")
	}
}

func TestOnlyVisibleCardsAreCaptured(t *testing.T) {
	m, fake := newTestModel(t, 45, 30, true)
	fake.snapshot = manyTerminals(12)
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	m.shots = map[string]shot{}
	m.inflight = map[string]int{}

	m.refreshShots()

	if got := len(m.inflight); got == 0 || got >= 12 {
		t.Fatalf("%d captures requested for 12 terminals: only the visible ones belong here", got)
	}
}

func TestFreshScreensAreNotCapturedAgainRightAway(t *testing.T) {
	m, _ := newTestModel(t, 45, 30, true)
	m.inflight = map[string]int{}

	m.refreshShots()

	if len(m.inflight) != 0 {
		t.Fatalf("screens read just now must be left alone, got %v", m.inflight)
	}
}

func TestWheelScrollsTheCardsAndTheFeedSelectionSurvives(t *testing.T) {
	m, fake := newTestModel(t, 45, 20, true)
	fake.snapshot = manyTerminals(8)
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	keep := m.selected

	m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelDown, Action: tea.MouseActionPress})
	if m.scroll != wheelStep {
		t.Fatalf("scroll = %d, want %d", m.scroll, wheelStep)
	}
	m.Update(tea.MouseMsg{Button: tea.MouseButtonWheelUp, Action: tea.MouseActionPress})
	if m.scroll != 0 {
		t.Fatalf("scroll = %d, want 0", m.scroll)
	}
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	if m.selected != keep {
		t.Fatalf("selection moved on refresh: %q -> %q", keep, m.selected)
	}
}

func TestKeyboardSelectionScrollsIntoView(t *testing.T) {
	m, fake := newTestModel(t, 45, 20, true)
	fake.snapshot = manyTerminals(8)
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	press(m, "down", "down", "down", "down")

	if m.scroll == 0 {
		t.Fatal("moving past the first screen must scroll")
	}
	selected, found := m.selectedCell()
	if !found || selected.area.y+selected.area.h > m.scroll+m.bodyHeight() {
		t.Fatalf("selected cell %+v is below the viewport (scroll=%d)", selected.area, m.scroll)
	}
}

func TestHelpScreenAnyKeyGoesBack(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)

	press(m, "?")
	if m.top().screen != screenHelp || !strings.Contains(m.View(), "Open the selected terminal") {
		t.Fatalf("help not shown:\n%s", m.View())
	}
	press(m, "x")
	if m.top().screen != screenHome {
		t.Fatal("any key closes the help")
	}
}

func TestDevicesScreenShowsTheListAndItsButtons(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)

	cmd := press(m, "d")
	drain(t, m, cmd)

	if m.top().screen != screenDevices {
		t.Fatalf("route = %+v", m.top())
	}
	text := m.View()
	for _, want := range []string{"laptop  machine", "tablet  phone", "[add device]"} {
		if !strings.Contains(text, want) {
			t.Errorf("devices lacks %q:\n%s", want, text)
		}
	}
}

func TestRefreshButtonReloadsTheMesh(t *testing.T) {
	m, fake := newTestModel(t, 70, 40, true)

	msgs := drain(t, m, press(m, "r"))

	if fake.refreshes != 1 {
		t.Fatalf("refreshes = %d", fake.refreshes)
	}
	reloaded := false
	for _, msg := range msgs {
		_, isFeed := msg.(feedMsg)
		reloaded = reloaded || isFeed
	}
	if !reloaded {
		t.Fatal("after refreshing the hub list the mesh is read again")
	}
}

func TestFailedActionsShowInTheStatusLine(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)

	m.Update(actionMsg{err: errFeedDown})

	if !strings.Contains(m.View(), "failed: hub unreachable") {
		t.Fatalf("view:\n%s", m.View())
	}
	m.now = func() time.Time { return fixedNow.Add(noticeLifetime * 2) }
	if strings.Contains(m.View(), "failed:") {
		t.Fatal("notices expire")
	}
}
