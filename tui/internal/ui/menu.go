package ui

import (
	"strconv"
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	menuMaxWidth = 72
	hintEnter    = "enter"
	hintEsc      = "esc"
)

// menuItem is one row of a list screen.
type menuItem struct {
	prefix string
	label  string
	hint   string
	dim    bool
	act    intent
}

// menuItems are the rows of the current list screen (machine menu, machine choice, projects).
func (m *Model) menuItems() []menuItem {
	switch m.top().screen {
	case screenMachine:
		return m.machineItems()
	case screenNewMachine:
		return m.machineChoiceItems()
	case screenNewProject:
		return m.projectItems()
	default:
		return nil
	}
}

func (m *Model) backItem() menuItem {
	return menuItem{label: backArrow + m.cat.Text(i18n.KeyWordBack), hint: hintEsc, dim: true, act: backIntent}
}

// machineItems is the menu of one machine: its main terminal, a new one, send, web.
func (m *Model) machineItems() []menuItem {
	host := m.top().arg
	machine, found := m.snap.FindMachine(host)
	if !found || !machine.IsReachable() {
		return []menuItem{
			{label: m.cat.Text(i18n.KeyWordWake), act: intent{verb: verbWake, arg: host}},
			m.backItem(),
		}
	}
	return []menuItem{
		{label: m.cat.Text(i18n.KeyMMMain), act: intent{verb: verbOpenMachine, arg: host}},
		{label: m.cat.Text(i18n.KeyMMNew), hint: "n", act: intent{verb: verbNewOn, arg: host}},
		{label: m.cat.Text(i18n.KeyMMSend), hint: "s", act: intent{verb: verbSend}},
		{label: m.cat.Text(i18n.KeyMMPort), hint: "w", act: intent{verb: verbWeb}},
		m.backItem(),
	}
}

// machineChoiceItems lists the machines for "new terminal": offline ones are dimmed.
func (m *Model) machineChoiceItems() []menuItem {
	items := make([]menuItem, 0, len(m.snap.Machines)+1)
	for _, machine := range m.snap.Machines {
		hint := m.cat.Text(i18n.KeyOnline)
		if !machine.IsReachable() {
			hint = m.cat.Text(i18n.KeyOffline)
		}
		items = append(items, menuItem{
			prefix: theme.MachineDot(machine.Color, machine.IsReachable()) + space, label: machine.Name,
			hint: hint, dim: !machine.IsReachable(), act: intent{verb: verbNewOn, arg: machine.Name},
		})
	}
	return append(items, m.backItem())
}

// projectItems lists the projects of the machine that match the typed text, plus the
// "new terminal with this name" row. The typed name goes first unless it is a project.
func (m *Model) projectItems() []menuItem {
	typed := strings.TrimSpace(m.input.Value())
	lowered := strings.ToLower(typed)
	items := []menuItem{}
	exact := false
	for _, name := range m.projects[m.top().arg] {
		if !strings.Contains(strings.ToLower(name), lowered) {
			continue
		}
		exact = exact || strings.ToLower(name) == lowered
		items = append(items, menuItem{label: name, hint: m.cat.Text(i18n.KeyProjectTag),
			act: intent{verb: verbCreate, arg: name, extra: name}})
	}
	if typed == "" {
		return items
	}
	free := menuItem{label: m.cat.Format(i18n.KeyCreateNamed, typed), hint: hintEnter, act: intent{verb: verbCreate, arg: typed}}
	if exact {
		return append(items, free)
	}
	return append([]menuItem{free}, items...)
}

// menuLines draws the rows; the selected one gets a bar and the accent color.
func menuLines(items []menuItem, cursor, width int) []string {
	lines := make([]string, 0, len(items))
	for i, item := range items {
		marker, label := space, theme.Text().Render(item.label)
		switch {
		case i == cursor:
			marker, label = theme.Accent().Render(selectionMark), theme.Accent().Bold(true).Render(item.label)
		case item.dim:
			label = theme.Dim().Render(item.label)
		}
		lines = append(lines, spread(marker+item.prefix+label, theme.Dim().Render(item.hint), width))
	}
	return lines
}

// menuNotes are the quiet lines under the rows (reading projects, nothing to pick).
func (m *Model) menuNotes() []string {
	if m.top().screen != screenNewProject {
		return nil
	}
	host := m.top().arg
	if _, cached := m.projects[host]; !cached {
		return []string{theme.Faint().Render(space + m.cat.Text(i18n.KeyProjectsLoading))}
	}
	if len(m.menuItems()) == 0 {
		return []string{theme.Faint().Render(space + m.cat.Text(i18n.KeyNoProjects))}
	}
	return nil
}

// menuTitle is the heading of a list screen.
func (m *Model) menuTitle() string {
	switch m.top().screen {
	case screenMachine:
		machine, _ := m.snap.FindMachine(m.top().arg)
		return theme.MachineDot(machine.Color, machine.IsReachable()) + space + m.top().arg
	case screenNewProject:
		return m.cat.Format(i18n.KeyTitleNew2, m.top().arg)
	default:
		return m.cat.Text(i18n.KeyTitleNew)
	}
}

// menuBody is a centered panel holding the rows of the current list screen.
func (m *Model) menuBody(width, height int) block {
	items := m.menuItems()
	panelWidth := min(width, menuMaxWidth)
	inner := panelWidth - panelPaddingCol - 2*panelBorderCol
	rows := append(menuLines(items, m.cursor, inner), m.menuNotes()...)
	panelHeight := min(height, len(rows)+panelFrameRows+panelTitleRows)
	hits := rowHits(len(items), inner, func(index int) intent {
		return intent{verb: verbPick, arg: strconv.Itoa(index)}
	})
	panel := framePanel(panelSpec{
		title: m.menuTitle(), rows: rows, hits: hits, width: panelWidth, height: panelHeight,
		offset: windowFor(m.cursor, panelRoom(panelHeight), len(rows)),
	})
	return centered(panel, width)
}

// centered moves a block to the middle of width columns.
func centered(content block, width int) block {
	if len(content.lines) == 0 {
		return content
	}
	shift := max((width-cellWidth(content.lines[0]))/2, 0)
	pad := strings.Repeat(space, shift)
	moved := make([]string, 0, len(content.lines))
	for _, line := range content.lines {
		moved = append(moved, pad+line)
	}
	return block{lines: moved, hits: shifted(content.hits, shift, 0)}
}
