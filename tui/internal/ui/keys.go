package ui

import (
	tea "github.com/charmbracelet/bubbletea"
)

// Key names as Bubble Tea reports them.
const (
	keyEnter    = "enter"
	keyEsc      = "esc"
	keyCtrlC    = "ctrl+c"
	keyUp       = "up"
	keyDown     = "down"
	keyLeft     = "left"
	keyRight    = "right"
	keyTab      = "tab"
	keyShiftTab = "shift+tab"
	keyPageUp   = "pgup"
	keyPageDown = "pgdown"
	keyHome     = "home"
	keyEnd      = "end"
	keyQuestion = "?"
	keySlash    = "/"
)

var (
	quitIntent = intent{verb: verbQuit}
	backIntent = intent{verb: verbBack}
	helpIntent = intent{verb: verbHelp}
)

// moveKeys are the keys that move the cursor on every list.
var moveKeys = map[string]string{
	keyUp: moveUp, "k": moveUp, keyDown: moveDown, "j": moveDown,
	keyLeft: moveLeft, "h": moveLeft, keyRight: moveRight, "l": moveRight,
	keyTab: moveRight, keyShiftTab: moveLeft,
	keyPageUp: movePageUp, keyPageDown: movePageDown,
	keyHome: moveFirst, "g": moveFirst, keyEnd: moveLast, "G": moveLast,
}

// commandKeys are the single-letter shortcuts, shared by the screens that offer the action.
var commandKeys = map[string]intent{
	"n": {verb: verbNew}, "s": {verb: verbSend}, "f": {verb: verbFetch}, "w": {verb: verbWeb},
	"d": {verb: verbDevices}, "a": {verb: verbAdd}, "r": {verb: verbRefresh},
}

// homeKeys are the keys that only mean something on the home screen.
var homeKeys = map[string]intent{
	keyEnter: {verb: verbActivate}, "o": {verb: verbOpenTerminal}, keySlash: {verb: verbFilter},
}

// handleKey routes a key press: the text input when one is active, else the shortcuts.
func (m *Model) handleKey(msg tea.KeyMsg) tea.Cmd {
	name := msg.String()
	if name == keyCtrlC {
		return m.applyIntent(quitIntent)
	}
	if m.typing() {
		return m.handleTypingKey(msg)
	}
	switch name {
	case "q":
		return m.applyIntent(quitIntent)
	case keyEsc:
		return m.applyIntent(backIntent)
	case keyQuestion:
		return m.applyIntent(helpIntent)
	}
	if m.top().screen == screenHelp {
		return m.applyIntent(backIntent)
	}
	return m.handleScreenKey(name)
}

// handleScreenKey applies the shortcuts of the current screen.
func (m *Model) handleScreenKey(name string) tea.Cmd {
	screenKind := m.top().screen
	if direction, found := moveKeys[name]; found && m.movable(screenKind) {
		return m.applyIntent(intent{verb: verbMove, arg: direction})
	}
	if name == keyEnter && screenKind != screenHome {
		return m.applyIntent(intent{verb: verbSubmit})
	}
	if act, found := homeKeys[name]; found && (screenKind == screenHome || (screenKind == screenDetail && act.verb == verbOpenTerminal)) {
		return m.applyIntent(act)
	}
	if act, found := commandKeys[name]; found && m.accepts(screenKind, act.verb) {
		return m.applyIntent(act)
	}
	return nil
}

// movable reports whether the screen has a cursor or a scroll position.
func (m *Model) movable(kind screen) bool { return kind != screenHelp && kind != screenDetail }

// accepts reports whether a shortcut action makes sense on a screen.
func (m *Model) accepts(kind screen, action verb) bool {
	switch kind {
	case screenHome, screenMachine, screenDetail:
		return true
	case screenDevices:
		return action == verbAdd || action == verbRefresh
	default:
		return false
	}
}

// handleTypingKey sends the key to the active text input, after the few keys that leave it.
func (m *Model) handleTypingKey(msg tea.KeyMsg) tea.Cmd {
	switch msg.String() {
	case keyEsc:
		return m.applyIntent(backIntent)
	case keyEnter:
		return m.applyIntent(intent{verb: verbSubmit})
	case keyUp, keyDown:
		if m.top().screen == screenNewProject {
			return m.applyIntent(intent{verb: verbMove, arg: moveKeys[msg.String()]})
		}
	}
	return m.typeInto(msg)
}

// typeInto feeds a key to the input of the screen and reacts to the new text.
func (m *Model) typeInto(msg tea.KeyMsg) tea.Cmd {
	field := &m.input
	if m.top().screen == screenHome {
		field = &m.filter
	}
	before := field.Value()
	updated, cmd := field.Update(msg)
	*field = updated
	if field.Value() != before {
		m.cursor = 0
		m.scroll = 0
		if m.top().screen == screenHome {
			m.resolveSelection()
		}
	}
	return cmd
}
