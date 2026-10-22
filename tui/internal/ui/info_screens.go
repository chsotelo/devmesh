package ui

import (
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	helpKeyWidth    = 14
	emptyCardWidth  = 56
	infoPanelMargin = 2
)

type helpRow struct {
	key   string
	label string
}

// helpRows are the shortcuts shown on the help screen.
func (m *Model) helpRows() []helpRow {
	text := m.cat.Text
	return []helpRow{
		{"↑ ↓ ← →  hjkl", text(i18n.KeyHelpMove)},
		{keyEnter, text(i18n.KeyHelpOpen)},
		{"o", text(i18n.KeyWordOpen)},
		{keyEsc, text(i18n.KeyHelpBack)},
		{"n", text(i18n.KeyActNew)},
		{"s", text(i18n.KeyActSend)},
		{"f", text(i18n.KeyActFetch)},
		{"w", text(i18n.KeyActPort)},
		{"d", text(i18n.KeyActDevices)},
		{"a", text(i18n.KeyActAdd)},
		{"r", text(i18n.KeyActRefresh)},
		{keySlash, text(i18n.KeyHelpFilter)},
		{"q", text(i18n.KeyActQuit)},
		{"tap", text(i18n.KeyHelpMouse)},
		{"C-a p · C-a n", text(i18n.KeyHelpTabs)},
	}
}

// helpBody is the shortcut sheet.
func (m *Model) helpBody(width, height int) block {
	panelWidth := min(width, menuMaxWidth)
	rows := make([]string, 0, len(m.helpRows()))
	for _, row := range m.helpRows() {
		rows = append(rows, theme.Accent().Render(padRight(row.key, helpKeyWidth))+theme.Text().Render(row.label))
	}
	panelHeight := min(height, len(rows)+panelFrameRows+panelTitleRows)
	return centered(framePanel(panelSpec{
		title: m.cat.Text(i18n.KeyTitleHelp), rows: rows, width: panelWidth, height: panelHeight,
	}), width)
}

// devicesBody shows the output of "dm devices" with the buttons to add one or refresh.
func (m *Model) devicesBody(width, height int) block {
	panelWidth := min(width, menuMaxWidth)
	inner := panelWidth - panelPaddingCol - 2*panelBorderCol
	var rows []string
	switch {
	case m.devicesBusy && m.devicesText == "":
		rows = []string{theme.Faint().Render(m.cat.Text(i18n.KeyLoading))}
	case m.devicesErr != "":
		rows = []string{theme.Error().Render(truncate(m.devicesErr, inner))}
	case m.devicesText == "":
		rows = []string{theme.Faint().Render(m.cat.Text(i18n.KeyDevicesEmpty))}
	default:
		for _, line := range splitLines(m.devicesText) {
			rows = append(rows, theme.Text().Render(truncate(line, inner)))
		}
	}
	buttons := []button{
		{label: m.cat.Text(i18n.KeyWordAdd), act: intent{verb: verbAdd}},
		{label: m.cat.Text(i18n.KeyActRefresh), act: intent{verb: verbDevices}},
	}
	row, hits := layoutButtons(buttons, 0, len(rows)+1)
	rows = append(rows, "", row)
	panelHeight := min(height, len(rows)+panelFrameRows+panelTitleRows)
	room := panelRoom(panelHeight)
	offset := min(m.cursor, max(len(rows)-room, 0))
	return centered(framePanel(panelSpec{
		title: m.cat.Text(i18n.KeyActDevices), rows: rows, hits: hits, offset: offset,
		width: panelWidth, height: panelHeight,
	}), width)
}

// emptyBody is the friendly first-run card: no machines yet.
func (m *Model) emptyBody(width, height int) block {
	cardWidth := min(width-infoPanelMargin*2, emptyCardWidth)
	inner := cardWidth - panelPaddingCol - 2*panelBorderCol
	add := button{label: m.cat.Text(i18n.KeyWordAdd), act: intent{verb: verbAdd}}
	rows := []string{
		"",
		theme.Bold().Render(center(m.cat.Text(i18n.KeyNoMachines), inner)),
		theme.Dim().Render(center(truncate(m.cat.Text(i18n.KeyNoMachinesWhy), inner), inner)),
		theme.Dim().Render(center(truncate(m.cat.Text(i18n.KeyNoMachinesAdd), inner), inner)),
		"",
	}
	label, hits := layoutButtons([]button{add}, (inner-add.width())/2, len(rows))
	rows = append(rows, label, "")
	card := framePanel(panelSpec{
		title: "devmesh", rows: rows, hits: hits, width: cardWidth, height: len(rows) + panelFrameRows + panelTitleRows,
	})
	return verticallyCentered(centered(card, width), height)
}

// verticallyCentered adds blank lines above a block (and moves its hits down).
func verticallyCentered(content block, height int) block {
	top := max((height-len(content.lines))/2, 0)
	lines := make([]string, 0, top+len(content.lines))
	for range top {
		lines = append(lines, "")
	}
	return block{lines: append(lines, content.lines...), hits: shifted(content.hits, 0, top)}
}

// messageBody is a single centered line (loading, a read error).
func (m *Model) messageBody(text string, width, height int) block {
	line := theme.Faint().Render(center(truncate(strings.TrimSpace(text), width), width))
	return verticallyCentered(block{lines: []string{line}}, height)
}
