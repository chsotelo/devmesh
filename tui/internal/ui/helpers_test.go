package ui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

func init() {
	// Tests drive the refresh themselves: the real ticks would wait seconds.
	feedTick = func() tea.Cmd { return nil }
	shotTick = func() tea.Cmd { return nil }
}

var namedKeys = map[string]tea.KeyType{
	"enter": tea.KeyEnter, "esc": tea.KeyEsc, "up": tea.KeyUp, "down": tea.KeyDown,
	"left": tea.KeyLeft, "right": tea.KeyRight, "ctrl+c": tea.KeyCtrlC, "tab": tea.KeyTab,
}

func keyMsg(name string) tea.KeyMsg {
	if kind, named := namedKeys[name]; named {
		return tea.KeyMsg{Type: kind}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(name)}
}

// press sends keys one by one (named keys or text) and returns the last command.
func press(m *Model, keys ...string) tea.Cmd {
	var last tea.Cmd
	for _, key := range keys {
		_, last = m.Update(keyMsg(key))
	}
	return last
}

// typeText sends each rune as its own key press.
func typeText(m *Model, text string) {
	for _, r := range text {
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
}

// drain runs a command and feeds every message it produces back into the model.
func drain(t *testing.T, m *Model, cmd tea.Cmd) []tea.Msg {
	t.Helper()
	var seen []tea.Msg
	pending := []tea.Cmd{cmd}
	for len(pending) > 0 {
		next := pending[0]
		pending = pending[1:]
		if next == nil {
			continue
		}
		msg, finished := runWithin(next)
		if !finished {
			continue
		}
		if batch, isBatch := msg.(tea.BatchMsg); isBatch {
			pending = append(pending, batch...)
			continue
		}
		seen = append(seen, msg)
		if _, isQuit := msg.(tea.QuitMsg); isQuit {
			continue
		}
		_, follow := m.Update(msg)
		pending = append(pending, follow)
	}
	return seen
}

// slowCommandLimit is how long a command may take before the test gives up on it: blinking
// cursors and timers never finish soon, while every action under test answers at once.
const slowCommandLimit = 150 * time.Millisecond

func runWithin(command tea.Cmd) (tea.Msg, bool) {
	result := make(chan tea.Msg, 1)
	go func() { result <- command() }()
	select {
	case msg := <-result:
		return msg, true
	case <-time.After(slowCommandLimit):
		return nil, false
	}
}

func wasQuit(msgs []tea.Msg) bool {
	for _, msg := range msgs {
		if _, isQuit := msg.(tea.QuitMsg); isQuit {
			return true
		}
	}
	return false
}

func viewLines(m *Model) []string { return strings.Split(m.View(), "\n") }

// hitFor finds the clickable area of an intent in the current frame.
func hitFor(t *testing.T, m *Model, want intent) hit {
	t.Helper()
	for _, h := range m.frame().hits {
		if h.act == want {
			return h
		}
	}
	t.Fatalf("no clickable area for %+v in:\n%s", want, m.View())
	return hit{}
}

func tapOn(m *Model, h hit) tea.Cmd {
	_, cmd := m.Update(tea.MouseMsg{X: h.area.x, Y: h.area.y, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress})
	return cmd
}

func countIn(lines []string, needle string) int {
	total := 0
	for _, line := range lines {
		total += strings.Count(line, needle)
	}
	return total
}

// manyTerminals is a mesh with n terminals on one machine, to test scrolling.
func manyTerminals(count int) feed.Snapshot {
	terms := make([]feed.Terminal, 0, count)
	for i := range count {
		name := "t" + string(rune('a'+i))
		terms = append(terms, feed.Terminal{Host: "lap", Session: name, Window: "1", Active: true, Command: "zsh", Activity: fixedNow.Unix() - 10})
	}
	return feed.Snapshot{Device: "tablet", Version: "0.9.0", Machines: []feed.Machine{
		{Name: "lap", Reach: feed.ReachOnline, Color: 33, Terminals: terms},
	}}
}

func singleMachineSnapshot() feed.Snapshot {
	snap := sampleSnapshot()
	snap.Machines = snap.Machines[:1]
	return snap
}
