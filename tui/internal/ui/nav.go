package ui

import (
	"strings"
)

// Move directions, the argument of verbMove.
const (
	moveUp       = "up"
	moveDown     = "down"
	moveLeft     = "left"
	moveRight    = "right"
	moveFirst    = "first"
	moveLast     = "last"
	movePageUp   = "pgup"
	movePageDown = "pgdn"
)

// bodyHeight is the room of the screen body: everything but the bars and the input box.
func (m *Model) bodyHeight() int {
	height := m.height - topBarHeight - bottomBarHeight
	if m.hasInputBox() {
		height -= inputBoxHeight
	}
	return max(height, 1)
}

// hasInputBox reports whether the rounded input is shown above the hints.
func (m *Model) hasInputBox() bool {
	switch current := m.top().screen; current {
	case screenNewProject, screenAdd:
		return true
	case screenTerminals:
		return m.filterOn || m.filter.Value() != ""
	default:
		return hasTextInput(current)
	}
}

// homeGeometry splits the body width between the cards and the detail pane.
func (m *Model) homeGeometry() (listWidth, detailWidth int) {
	if !m.wide() {
		return m.width, 0
	}
	detailWidth = max(m.width*45/100, 50)
	return m.width - detailWidth - cardGap, detailWidth
}

// homeLayout lays the cards out for the current size, data and filter.
func (m *Model) homeLayout() homeLayout {
	listWidth, _ := m.homeGeometry()
	return layoutHome(homeParams{
		snap: m.snap, shots: m.shotLines(), filter: strings.TrimSpace(m.filter.Value()),
		width: listWidth, height: m.bodyHeight(), selected: m.selected,
		now: m.now(), cat: m.cat,
	})
}

func (m *Model) shotLines() map[string]shot { return m.shots }

// resolveSelection keeps the selection on something that exists.
func (m *Model) resolveSelection() {
	layout := m.homeLayout()
	for _, c := range layout.cells {
		if c.key == m.selected {
			return
		}
	}
	m.selected = ""
	for _, c := range layout.cells {
		if c.kind == cellTerminal {
			m.selected = c.key
			return
		}
	}
	if len(layout.cells) > 0 {
		m.selected = layout.cells[0].key
	}
}

// selectedCell returns the cell under the cursor.
func (m *Model) selectedCell() (cell, bool) {
	for _, c := range m.homeLayout().cells {
		if c.key == m.selected {
			return c, true
		}
	}
	return cell{}, false
}

// moveSelection moves the cursor on the home grid.
func (m *Model) moveSelection(direction string) {
	layout := m.homeLayout()
	if len(layout.cells) == 0 {
		return
	}
	current := 0
	for i, c := range layout.cells {
		if c.key == m.selected {
			current = i
		}
	}
	target := targetCell(layout.cells, current, direction)
	m.selected = layout.cells[target].key
	m.ensureVisible()
}

// targetCell finds where a direction leads from cells[current].
func targetCell(cells []cell, current int, direction string) int {
	last := len(cells) - 1
	switch direction {
	case moveLeft:
		return max(current-1, 0)
	case moveRight:
		return min(current+1, last)
	case moveFirst:
		return 0
	case moveLast:
		return last
	case moveUp, movePageUp:
		return nearestVertical(cells, current, -1, repeatFor(direction))
	case moveDown, movePageDown:
		return nearestVertical(cells, current, 1, repeatFor(direction))
	default:
		return current
	}
}

const pageMoves = 3

func repeatFor(direction string) int {
	if direction == movePageUp || direction == movePageDown {
		return pageMoves
	}
	return 1
}

// nearestVertical walks up or down the grid `steps` times.
func nearestVertical(cells []cell, current, sign, steps int) int {
	for range steps {
		next := verticalNeighbour(cells, current, sign)
		if next == current {
			break
		}
		current = next
	}
	return current
}

// verticalNeighbour picks the closest cell above or below, preferring the same column.
func verticalNeighbour(cells []cell, current, sign int) int {
	from := cells[current].area
	best := current
	for i, c := range cells {
		if !isBeyond(from, c.area, sign) {
			continue
		}
		if best == current || isCloser(from, c.area, cells[best].area, sign) {
			best = i
		}
	}
	return best
}

func isBeyond(from, other rect, sign int) bool {
	if sign > 0 {
		return other.y >= from.y+from.h
	}
	return other.y+other.h <= from.y
}

func isCloser(from, candidate, best rect, sign int) bool {
	if candidate.y != best.y {
		if sign > 0 {
			return candidate.y < best.y
		}
		return candidate.y > best.y
	}
	return abs(candidate.x-from.x) < abs(best.x-from.x)
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

// ensureVisible scrolls the home body so the selected cell is on screen.
func (m *Model) ensureVisible() {
	layout := m.homeLayout()
	view := m.bodyHeight()
	for _, c := range layout.cells {
		if c.key != m.selected {
			continue
		}
		top := c.area.y
		if c.kind == cellTerminal {
			top = max(top-1, 0)
		}
		if top < m.scroll {
			m.scroll = top
		} else if c.area.y+c.area.h > m.scroll+view {
			m.scroll = c.area.y + c.area.h - view
		}
	}
	m.scroll = clampScroll(m.scroll, len(layout.lines), view)
}

// clampScroll keeps the first visible line inside the content.
func clampScroll(scroll, total, view int) int {
	return min(max(scroll, 0), max(total-view, 0))
}
