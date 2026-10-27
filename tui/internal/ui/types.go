// Package ui is the Bubble Tea application: screens, layout, keys and mouse.
package ui

// screen is one page of the panel.
type screen int

// The screens, in the order of the user's journey.
const (
	// screenHome is the Claude sessions of one machine; the terminals are one tap away.
	screenHome screen = iota
	screenTerminals
	screenSession
	screenPick
	screenMove
	screenHistory
	screenHistoryItem
	screenClaudeNew
	screenMachine
	screenDetail
	screenNewMachine
	screenNewProject
	screenAdd
	screenDevices
	screenHelp
)

// route is a screen with its argument (a machine name, a terminal key).
type route struct {
	screen screen
	arg    string
}

// verb is what the user asked for, whatever the way (key, tap, button).
type verb int

// The verbs. Everything that changes the panel goes through one of them.
const (
	verbNone verb = iota
	verbSelect
	verbActivate
	verbOpenTerminal
	verbNew
	verbNewOn
	verbSend
	verbFetch
	verbWeb
	verbDevices
	verbRefresh
	verbAdd
	verbHelp
	verbBack
	verbQuit
	verbWake
	verbOpenMachine
	verbPick
	verbFilter
	verbSubmit
	verbMove
	verbCreate
	verbSay
	verbOpenClaude
	verbViewMachine
	verbPickMachine
	verbStop
	verbStopIdle
	verbMoveTo
	verbMoveMenu
	verbHistory
	verbTerminals
	verbResume
	verbHistoryItem
	verbClaudeCreate
)

// intent is a verb with its argument.
type intent struct {
	verb  verb
	arg   string
	extra string
}

// rect is a screen area in cells.
type rect struct {
	x, y, w, h int
}

func (r rect) contains(x, y int) bool {
	return x >= r.x && x < r.x+r.w && y >= r.y && y < r.y+r.h
}

// hit is a clickable area and what a tap on it does.
type hit struct {
	area rect
	act  intent
}

// block is a rectangle of rendered lines with its clickable areas, in its own coordinates.
type block struct {
	lines []string
	hits  []hit
}

// shifted returns the hits moved by (dx, dy).
func shifted(hits []hit, dx, dy int) []hit {
	moved := make([]hit, 0, len(hits))
	for _, h := range hits {
		h.area.x += dx
		h.area.y += dy
		moved = append(moved, h)
	}
	return moved
}

// clipped keeps the hits that overlap rows [top, top+height) and moves them to start at 0.
func clipped(hits []hit, top, height int) []hit {
	kept := make([]hit, 0, len(hits))
	for _, h := range hits {
		bottom := h.area.y + h.area.h
		if bottom <= top || h.area.y >= top+height {
			continue
		}
		h.area.y -= top
		kept = append(kept, h)
	}
	return kept
}
