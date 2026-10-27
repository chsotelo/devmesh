package ui

import (
	"strings"
	"testing"
)

func TestNewTerminalAsksForTheMachineWhenThereAreSeveral(t *testing.T) {
	m, _ := newTerminalsModel(t, 70, 40, true)

	press(m, "n")

	if m.top().screen != screenNewMachine {
		t.Fatalf("route = %+v", m.top())
	}
	text := m.View()
	for _, want := range []string{"new terminal › machine", "laptop", "online", "desktop", "offline"} {
		if !strings.Contains(text, want) {
			t.Errorf("machine choice lacks %q:\n%s", want, text)
		}
	}
	if m.cursor != 0 {
		t.Fatalf("cursor starts on the selected terminal's machine, got row %d", m.cursor)
	}
}

func TestNewTerminalSkipsTheMachineStepWithASingleMachine(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot = singleMachineSnapshot()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	drain(t, m, press(m, "n"))

	if got := m.top(); got.screen != screenNewProject || got.arg != "laptop" {
		t.Fatalf("route = %+v", got)
	}
}

func TestNewTerminalWithoutMachinesSaysSo(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot.Machines = nil
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	press(m, "n")

	if text, _ := m.activeNotice(); text != "no machines yet: add one" || m.top().screen != screenTerminals {
		t.Fatalf("notice=%q route=%+v", text, m.top())
	}
}

func TestTypingANameCreatesAFreeTerminal(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot = singleMachineSnapshot()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	drain(t, m, press(m, "n"))

	typeText(m, "mob")
	text := m.View()
	for _, want := range []string{"new terminal › laptop › project", `+ New terminal "mob"`, "mobile", "project"} {
		if !strings.Contains(text, want) {
			t.Errorf("project step lacks %q:\n%s", want, text)
		}
	}
	drain(t, m, press(m, "enter"))

	if len(fake.created) != 1 || fake.created[0] != "laptop|mob|" {
		t.Fatalf("created = %v", fake.created)
	}
	if m.top().screen != screenHome {
		t.Fatalf("route = %+v", m.top())
	}
}

func TestPickingAProjectCreatesItsTerminalInThatFolder(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot = singleMachineSnapshot()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	drain(t, m, press(m, "n"))

	press(m, "down")
	drain(t, m, press(m, "enter"))

	if len(fake.created) != 1 || fake.created[0] != "laptop|docs|docs" {
		t.Fatalf("created = %v", fake.created)
	}
}

func TestAnExactProjectMatchComesBeforeTheFreeNameRow(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot = singleMachineSnapshot()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	drain(t, m, press(m, "n"))

	typeText(m, "api")
	items := m.menuItems()

	if len(items) != 2 || items[0].label != "api" || items[1].act.verb != verbCreate || items[1].act.extra != "" {
		t.Fatalf("items = %+v", items)
	}
}

func TestEnterWithNothingTypedAndNoProjectsAsksForAName(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot = singleMachineSnapshot()
	fake.projects = nil
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	drain(t, m, press(m, "n"))

	press(m, "enter")

	if text, _ := m.activeNotice(); text != "type the terminal name above" {
		t.Fatalf("notice = %q", text)
	}
}

func TestOutsideTmuxCreatingValidatesBeforeTakingTheScreen(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, false)
	fake.snapshot = singleMachineSnapshot()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	drain(t, m, press(m, "n"))
	typeText(m, "web")

	msgs := drain(t, m, press(m, "enter"))

	if len(fake.validated) != 1 || fake.validated[0] != "laptop|web|" {
		t.Fatalf("validated = %v", fake.validated)
	}
	if len(fake.created) != 0 {
		t.Fatal("the creation itself runs full screen, not in the background")
	}
	foundNext := false
	for _, msg := range msgs {
		if done, isAction := msg.(actionMsg); isAction && done.next != nil {
			foundNext = true
		}
	}
	if !foundNext {
		t.Fatal("after validating, the full screen command must follow")
	}
}

func TestEscLeavesTheProjectStepAndClearsTheTypedName(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 40, true)
	fake.snapshot = singleMachineSnapshot()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})
	drain(t, m, press(m, "n"))
	typeText(m, "abc")

	press(m, "esc")

	if m.top().screen != screenTerminals || m.input.Value() != "" {
		t.Fatalf("route=%+v input=%q", m.top(), m.input.Value())
	}
}

func TestAddDeviceRejectsABadNameAndAcceptsAGoodOne(t *testing.T) {
	m, _ := newTerminalsModel(t, 70, 40, true)
	press(m, "a")
	if m.top().screen != screenAdd {
		t.Fatalf("route = %+v", m.top())
	}
	if !strings.Contains(m.View(), "Generates the line to join a new device") {
		t.Fatalf("the add screen must explain itself:\n%s", m.View())
	}

	typeText(m, "Bad Name")
	press(m, "enter")
	if m.top().screen != screenAdd {
		t.Fatal("a bad name keeps the user on the form")
	}
	if text, isError := m.activeNotice(); !strings.HasPrefix(text, "name: lowercase") || !isError {
		t.Fatalf("notice = %q", text)
	}

	press(m, "esc")
	press(m, "a")
	typeText(m, "lap-2")
	cmd := press(m, "enter")

	if cmd == nil || m.top().screen != screenTerminals {
		t.Fatalf("cmd=%v route=%+v", cmd, m.top())
	}
}

func TestShortcutsDoNotFireWhileTypingAName(t *testing.T) {
	m, _ := newTerminalsModel(t, 70, 40, true)
	press(m, "a")

	typeText(m, "send")

	if m.top().screen != screenAdd || m.input.Value() != "send" {
		t.Fatalf("route=%+v input=%q", m.top(), m.input.Value())
	}
}

func TestMachineMenuShortcutsActOnThatMachine(t *testing.T) {
	m, _ := newTerminalsModel(t, 70, 50, true)
	press(m, "up", "enter")

	press(m, "n")

	if got := m.top(); got.screen != screenNewProject || got.arg != "laptop" {
		t.Fatalf("route = %+v", got)
	}
}

func TestMachineMenuMainTerminalOpensTheMainSession(t *testing.T) {
	m, fake := newTerminalsModel(t, 70, 50, true)
	press(m, "up", "enter")

	drain(t, m, press(m, "enter"))

	if len(fake.opened) != 1 || fake.opened[0] != "laptop/main/" {
		t.Fatalf("opened = %v", fake.opened)
	}
}
