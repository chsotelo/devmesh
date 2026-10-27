package sidebar

import (
	"errors"
	"strings"
	"testing"

	"github.com/chsotelo/devmesh/tui/internal/source"
)

// openPowerMenu taps the footer entry and feeds the answer of dm back.
func openPowerMenu(t *testing.T, m *Model, src *fakeSource, state source.PowerState) {
	t.Helper()
	src.power = state
	tapText(t, m, powerGlyph)
	if m.claude.mode != modePower {
		t.Fatalf("the power entry did not open the menu:\n%s", m.View())
	}
}

func callsOf(src *fakeSource) string { return strings.Join(src.calls, ";") }

func TestPowerEntryIsInTheFooterAndAsksDmWhatIsAllowed(t *testing.T) {
	for _, width := range []int{24, 44, 60} {
		m, src := claudeModel(t, width, 30)
		if !strings.Contains(m.View(), powerGlyph) {
			t.Fatalf("width %d: no %s in the footer:\n%s", width, powerGlyph, m.View())
		}
		fits(t, m)
		openPowerMenu(t, m, src, source.PowerState{Suspend: true, Off: true, Why: "ok"})
		if got := callsOf(src); got != "powercheck lap" {
			t.Fatalf("calls = %q", got)
		}
	}
}

func TestPowerMenuOffersOnlyWhatDmAllows(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Suspend: true, Why: "ok"})

	view := m.View()

	if !strings.Contains(view, "Suspend") || strings.Contains(view, "Power off") || strings.Contains(view, "Wake") {
		t.Fatalf("menu:\n%s", view)
	}
	fits(t, m)
}

func TestPowerMenuOfflineMachineOffersWake(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Wake: true, Why: "ok"})

	tapText(t, m, "Wake")

	if got := callsOf(src); !strings.HasSuffix(got, "power lap wake") {
		t.Fatalf("calls = %q", got)
	}
	if m.claude.mode != modeClaude || !strings.Contains(m.View(), "wake-up sent to lap") {
		t.Fatalf("after waking:\n%s", m.View())
	}
}

func TestPowerMenuSuspendRunsAndReports(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Suspend: true, Off: true, Why: "ok"})

	tapText(t, m, "Suspend")

	if got := callsOf(src); !strings.Contains(got, "power lap suspend") {
		t.Fatalf("calls = %q", got)
	}
	if !strings.Contains(m.View(), "suspending lap") {
		t.Fatalf("view:\n%s", m.View())
	}
}

func TestPowerOffAsksASecondConfirmationAndNothingRunsBeforeIt(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Suspend: true, Off: true, Why: "ok"})

	tapText(t, m, "Power off")

	view := m.View()
	if strings.Contains(callsOf(src), "power lap off") {
		t.Fatalf("powered off without confirming: %q", callsOf(src))
	}
	for _, want := range []string{"power button", "Yes, power off", "Cancel"} {
		if !strings.Contains(view, want) {
			t.Fatalf("confirmation lacks %q:\n%s", want, view)
		}
	}
	fits(t, m)

	tapText(t, m, "Yes, power off")

	if got := callsOf(src); !strings.HasSuffix(got, "power lap off") {
		t.Fatalf("calls = %q", got)
	}
}

func TestPowerOffCancelAndEscapeNeverRunIt(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Off: true, Why: "ok"})
	tapText(t, m, "Power off")
	tapText(t, m, "Cancel")
	if m.claude.mode != modeClaude || strings.Contains(callsOf(src), "power lap") {
		t.Fatalf("mode=%v calls=%q", m.claude.mode, callsOf(src))
	}

	openPowerMenu(t, m, src, source.PowerState{Off: true, Why: "ok"})
	send(m, "enter")
	send(m, "esc")
	if m.claude.mode != modeClaude || strings.Contains(callsOf(src), "power lap off") {
		t.Fatalf("mode=%v calls=%q", m.claude.mode, callsOf(src))
	}
}

func TestPowerMenuShowsTheReasonWhenNothingIsAllowed(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Why: "other-lan"})

	view := m.View()

	if !strings.Contains(view, "woken from here") {
		t.Fatalf("reason missing:\n%s", view)
	}
	for _, word := range []string{"Suspend", "Power off", "Wake"} {
		if strings.Contains(view, word+"\n") {
			t.Fatalf("%q offered:\n%s", word, view)
		}
	}
}

func TestPowerFailureIsReportedAndNothingElseRuns(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	src.powerErr = errors.New("this machine does not allow it")
	openPowerMenu(t, m, src, source.PowerState{Suspend: true, Why: "ok"})

	tapText(t, m, "Suspend")

	if !strings.Contains(m.View(), "does not allow it") {
		t.Fatalf("view:\n%s", m.View())
	}
}

func TestSessionShortcutsDoNotActInThePowerMenu(t *testing.T) {
	m, src := claudeModel(t, 44, 30)
	openPowerMenu(t, m, src, source.PowerState{Suspend: true, Why: "ok"})
	src.calls = nil

	send(m, "x", "m", "n", "t", "H")

	if len(src.calls) != 0 || m.claude.mode != modePower {
		t.Fatalf("mode=%v calls=%v", m.claude.mode, src.calls)
	}
}
