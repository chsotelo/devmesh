package ui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestTopBarButtonsAreClickable(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	cases := map[verb]screen{verbNew: screenNewMachine, verbDevices: screenDevices}

	for action, want := range cases {
		model, _ := newTestModel(t, 70, 40, true)
		drain(t, model, tapOn(model, hitFor(t, model, intent{verb: action})))
		if model.top().screen != want {
			t.Errorf("tapping verb %d led to screen %d, want %d", action, model.top().screen, want)
		}
	}
	hitFor(t, m, intent{verb: verbSend})
	hitFor(t, m, intent{verb: verbWeb})
	hitFor(t, m, intent{verb: verbFetch})
	hitFor(t, m, intent{verb: verbRefresh})
}

func TestTopBarButtonsAreOnTheFirstRowAndInsideTheScreen(t *testing.T) {
	for _, width := range []int{45, 70, 160} {
		m, _ := newTestModel(t, width, 40, true)
		for _, h := range m.topBar().hits {
			if h.area.y != 0 || h.area.x < 0 || h.area.x+h.area.w > width {
				t.Fatalf("width %d: button %+v is off the bar", width, h)
			}
		}
	}
}

func TestPhoneKeepsTheMostImportantButtons(t *testing.T) {
	m, _ := newTestModel(t, 45, 30, true)

	hitFor(t, m, intent{verb: verbNew})
	hitFor(t, m, intent{verb: verbRefresh})
	for _, h := range m.topBar().hits {
		if h.act.verb == verbDevices {
			t.Fatal("the devices button does not fit on a phone")
		}
	}
}

func TestTapSelectsACardAndTapAgainOpensIt(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)
	web := hitFor(t, m, intent{verb: verbSelect, arg: "t:laptop/web/1"})

	tapOn(m, web)
	if m.selected != "t:laptop/web/1" || m.top().screen != screenHome {
		t.Fatalf("first tap selects only: selected=%q route=%+v", m.selected, m.top())
	}
	tapOn(m, web)
	if got := m.top(); got.screen != screenDetail || got.arg != "laptop/web/1" {
		t.Fatalf("second tap opens the detail: %+v", got)
	}
}

func TestTapOnWideScreenSecondTapOpensTheTerminal(t *testing.T) {
	m, fake := newTestModel(t, 160, 45, true)
	docs := hitFor(t, m, intent{verb: verbSelect, arg: "t:laptop/docs/1"})

	tapOn(m, docs)
	drain(t, m, tapOn(m, docs))

	if len(fake.opened) != 1 || fake.opened[0] != "laptop/docs/1" {
		t.Fatalf("opened = %v", fake.opened)
	}
}

func TestTapOnWakeButtonRunsTheWakeTool(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)

	cmd := tapOn(m, hitFor(t, m, intent{verb: verbWake, arg: "desktop"}))

	if cmd == nil || m.lastIntent != (intent{verb: verbWake, arg: "desktop"}) {
		t.Fatalf("cmd=%v intent=%+v", cmd, m.lastIntent)
	}
}

func TestTapOnMachineHeaderButtonStartsANewTerminalThere(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)

	tapOn(m, hitFor(t, m, intent{verb: verbNewOn, arg: "laptop"}))

	if got := m.top(); got.screen != screenNewProject || got.arg != "laptop" {
		t.Fatalf("route = %+v", got)
	}
}

func TestTapOnEmptyMeshAddButton(t *testing.T) {
	m, fake := newTestModel(t, 70, 30, true)
	fake.snapshot.Machines = nil
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	tapOn(m, hitFor(t, m, intent{verb: verbAdd}))

	if m.top().screen != screenAdd {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestTapOutsideAnyButtonDoesNothing(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)
	before := m.top()

	_, cmd := m.Update(tea.MouseMsg{X: 69, Y: 49, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})

	if cmd != nil || m.top() != before {
		t.Fatalf("cmd=%v route=%+v", cmd, m.top())
	}
}

func TestReleaseAndMotionDoNotTap(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)
	h := hitFor(t, m, intent{verb: verbNew})

	m.Update(tea.MouseMsg{X: h.area.x, Y: h.area.y, Button: tea.MouseButtonLeft, Action: tea.MouseActionRelease})
	m.Update(tea.MouseMsg{X: h.area.x, Y: h.area.y, Button: tea.MouseButtonNone, Action: tea.MouseActionMotion})

	if m.top().screen != screenHome {
		t.Fatal("only a press is a tap")
	}
}

func TestMenuRowsActOnTap(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	press(m, "n")
	if m.top().screen != screenNewMachine {
		t.Fatalf("route = %+v", m.top())
	}

	tapOn(m, hitFor(t, m, intent{verb: verbPick, arg: "0"}))

	if got := m.top(); got.screen != screenNewProject || got.arg != "laptop" {
		t.Fatalf("route = %+v", got)
	}
}

func TestTappingAnOfflineMachineInTheChoiceExplainsWhy(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	press(m, "n")

	tapOn(m, hitFor(t, m, intent{verb: verbPick, arg: "1"}))

	if m.top().screen != screenNewMachine {
		t.Fatalf("an offline machine cannot be chosen: %+v", m.top())
	}
	if text, isError := m.activeNotice(); text != "that machine is off" || !isError {
		t.Fatalf("notice = %q %v", text, isError)
	}
}

func TestBackButtonReturnsHome(t *testing.T) {
	m, _ := newTestModel(t, 70, 40, true)
	press(m, "?")

	tapOn(m, hitFor(t, m, backIntent))

	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}
