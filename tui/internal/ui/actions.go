package ui

import (
	"context"
	"os/exec"
	"strconv"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

// perform executes an intent, whatever produced it (a key, a tap, a button).
func (m *Model) applyIntent(act intent) tea.Cmd {
	m.lastIntent = act
	switch act.verb {
	case verbSelect:
		return m.selectCell(act.arg)
	case verbActivate:
		return m.activateSelected()
	case verbOpenTerminal:
		return m.openTerminal(act.arg)
	case verbNew:
		return m.startNew("")
	case verbNewOn:
		return m.startNew(act.arg)
	case verbSend:
		return m.runTool(source.ToolSend)
	case verbFetch:
		return m.runTool(source.ToolFetch)
	case verbWeb:
		return m.runTool(source.ToolPort)
	case verbDevices:
		return m.showDevices()
	case verbRefresh:
		return m.refreshAll()
	case verbAdd:
		return m.openAdd()
	case verbHelp:
		m.push(route{screen: screenHelp})
	case verbBack:
		return m.goBack()
	case verbQuit:
		m.finished = true
		return tea.Quit
	case verbWake:
		return m.runTool(source.ToolWake, act.arg)
	case verbOpenMachine:
		return m.openTerminalByName(act.arg, mainSession)
	case verbPick:
		return m.pickItem(act.arg)
	case verbFilter:
		return m.startFilter()
	case verbSubmit:
		return m.submit()
	case verbMove:
		return m.move(act.arg)
	case verbCreate:
		return m.createTerminal(act.arg, act.extra)
	}
	return nil
}

const mainSession = "main"

// selectCell is a tap on a card: the first tap selects it, tapping the selected one opens it.
func (m *Model) selectCell(key string) tea.Cmd {
	if key == m.selected {
		return m.activateSelected()
	}
	m.selected = key
	m.ensureVisible()
	return m.refreshShots()
}

// activateSelected opens the selected card: the terminal itself when the detail pane is on
// screen, else its detail view. A machine opens its menu (or wakes up when offline).
func (m *Model) activateSelected() tea.Cmd {
	picked, found := m.selectedCell()
	if !found {
		return nil
	}
	if picked.kind == cellMachine {
		machine, known := m.snap.FindMachine(picked.host)
		switch {
		case !known:
			return nil
		case machine.IsReachable():
			m.push(route{screen: screenMachine, arg: machine.Name})
			return nil
		default:
			return m.runTool(source.ToolWake, machine.Name)
		}
	}
	if m.wide() {
		return m.openTerminalCommand(picked.term)
	}
	m.push(route{screen: screenDetail, arg: picked.term.Key()})
	return m.refreshShots()
}

// openTerminal opens the terminal with that key; empty means the one the user is looking at.
func (m *Model) openTerminal(key string) tea.Cmd {
	if key == "" {
		key = m.focusedTerminalKey()
	}
	term, found := m.snap.FindTerminal(key)
	if !found {
		return nil
	}
	return m.openTerminalCommand(term)
}

func (m *Model) focusedTerminalKey() string {
	if current := m.top(); current.screen == screenDetail {
		return current.arg
	}
	if picked, found := m.selectedCell(); found && picked.kind == cellTerminal {
		return picked.term.Key()
	}
	return ""
}

// openTerminalByName opens a session that may not exist yet (the main terminal of a machine).
func (m *Model) openTerminalByName(host, session string) tea.Cmd {
	return m.openTerminalCommand(feed.Terminal{Host: host, Session: session})
}

// openTerminalCommand opens a terminal: as a tab when inside tmux (the panel stays), else
// full screen, and the panel comes back when the terminal is left.
func (m *Model) openTerminalCommand(term feed.Terminal) tea.Cmd {
	if m.inTmux {
		reader := m.src
		return backgroundAction(func(ctx context.Context) error {
			return reader.Open(ctx, term.Host, term.Session, term.Window)
		}, actionMsg{goHome: true})
	}
	return m.foreground(m.src.OpenCommand(term.Host, term.Session, term.Window), true)
}

// foreground runs a command that takes the screen; nil means the arguments were refused.
func (m *Model) foreground(command *exec.Cmd, goHome bool) tea.Cmd {
	if command == nil {
		m.say(m.failure(source.ErrInvalidArgument), true)
		return nil
	}
	return tea.ExecProcess(command, func(err error) tea.Msg { return execDoneMsg{err: err, goHome: goHome} })
}

// runTool runs one of dm's full screen tools (send, fetch, web, wake, add device).
func (m *Model) runTool(tool string, args ...string) tea.Cmd {
	return m.foreground(m.src.ToolCommand(tool, args...), false)
}

// startNew begins the guided "new terminal": machine (when there are several), then project.
func (m *Model) startNew(host string) tea.Cmd {
	machines := m.snap.Machines
	if current := m.top(); host == "" && current.screen == screenMachine {
		host = current.arg
	}
	switch {
	case len(machines) == 0:
		m.say(m.cat.Text(i18n.KeySayNoMachines), true)
		return nil
	case host != "":
		return m.pickMachine(host)
	case len(machines) == 1:
		return m.pickMachine(machines[0].Name)
	}
	m.push(route{screen: screenNewMachine})
	m.cursor = m.machineIndex(m.focusedHost())
	return nil
}

func (m *Model) focusedHost() string {
	if picked, found := m.selectedCell(); found {
		return picked.host
	}
	return ""
}

func (m *Model) machineIndex(host string) int {
	for i, machine := range m.snap.Machines {
		if machine.Name == host {
			return i
		}
	}
	return 0
}

// pickMachine moves to the project step for an online machine.
func (m *Model) pickMachine(host string) tea.Cmd {
	machine, found := m.snap.FindMachine(host)
	if !found || !machine.IsReachable() {
		m.say(m.cat.Text(i18n.KeySayMachineOff), true)
		return nil
	}
	if m.top().screen == screenNewMachine {
		m.pop()
	}
	m.push(route{screen: screenNewProject, arg: host})
	m.input.SetValue("")
	cmds := []tea.Cmd{m.input.Focus(), textinput.Blink}
	if _, cached := m.projects[host]; !cached {
		cmds = append(cmds, m.fetchProjects(host))
	}
	return tea.Batch(cmds...)
}

func (m *Model) showDevices() tea.Cmd {
	if m.top().screen != screenDevices {
		m.push(route{screen: screenDevices})
	}
	return m.fetchDevices()
}

func (m *Model) openAdd() tea.Cmd {
	m.push(route{screen: screenAdd})
	m.input.SetValue("")
	return tea.Batch(m.input.Focus(), textinput.Blink)
}

func (m *Model) startFilter() tea.Cmd {
	m.filterOn = true
	return tea.Batch(m.filter.Focus(), textinput.Blink)
}

// refreshAll re-reads the device list from the hub and then the mesh.
func (m *Model) refreshAll() tea.Cmd {
	m.say(m.cat.Text(i18n.KeyRefreshing), false)
	reader := m.src
	return backgroundAction(reader.Refresh, actionMsg{reload: true})
}

// goBack is Esc: leave the filter, then the screen, and quit from home.
func (m *Model) goBack() tea.Cmd {
	if m.top().screen == screenHome {
		return m.leaveHome()
	}
	m.pop()
	return nil
}

func (m *Model) leaveHome() tea.Cmd {
	if m.filterOn || m.filter.Value() != "" {
		m.filterOn = false
		m.filter.Blur()
		m.filter.SetValue("")
		m.scroll = 0
		m.resolveSelection()
		return nil
	}
	return m.applyIntent(quitIntent)
}

// move applies a direction on the screen's list.
func (m *Model) move(direction string) tea.Cmd {
	switch m.top().screen {
	case screenHome:
		m.moveSelection(direction)
		return m.refreshShots()
	case screenDevices:
		m.cursor = max(m.cursor+listStep(direction), 0)
	default:
		m.moveCursor(listStep(direction))
	}
	return nil
}

func listStep(direction string) int {
	switch direction {
	case moveUp, moveLeft:
		return -1
	case moveDown, moveRight:
		return 1
	case movePageUp:
		return -pageMoves
	case movePageDown:
		return pageMoves
	default:
		return 0
	}
}

func (m *Model) moveCursor(step int) {
	total := len(m.menuItems())
	m.cursor = min(max(m.cursor+step, 0), max(total-1, 0))
}

// createTerminal creates (or enters) a terminal on the machine of the project screen. dm
// validates the name: inside tmux that happens as the tab opens; otherwise it is checked
// first, because the full screen attach would hide the error.
func (m *Model) createTerminal(name, project string) tea.Cmd {
	host, reader := m.top().arg, m.src
	if m.inTmux {
		return backgroundAction(func(ctx context.Context) error {
			return reader.Create(ctx, host, name, project)
		}, actionMsg{goHome: true})
	}
	next := m.foreground(reader.CreateCommand(host, name, project), true)
	if next == nil {
		return nil
	}
	return backgroundAction(func(ctx context.Context) error {
		return reader.Validate(ctx, host, name, project)
	}, actionMsg{next: next})
}

// pickItem is a tap on a menu row: it selects the row and does what it says.
func (m *Model) pickItem(arg string) tea.Cmd {
	index, err := strconv.Atoi(arg)
	items := m.menuItems()
	if err != nil || index < 0 || index >= len(items) {
		return nil
	}
	m.cursor = index
	return m.applyIntent(items[index].act)
}

// submit is Enter on every screen but the home grid.
func (m *Model) submit() tea.Cmd {
	switch m.top().screen {
	case screenAdd:
		return m.submitDevice()
	case screenDetail:
		return m.openTerminal(m.top().arg)
	case screenHome:
		m.filterOn = false
		m.filter.Blur()
		return nil
	case screenDevices, screenHelp:
		return nil
	default:
		if len(m.menuItems()) == 0 {
			m.say(m.cat.Text(i18n.KeySayNameTerm), true)
			return nil
		}
		return m.pickItem(strconv.Itoa(m.cursor))
	}
}

func (m *Model) submitDevice() tea.Cmd {
	name := strings.TrimSpace(m.input.Value())
	if !source.ValidDeviceName(name) {
		m.say(m.cat.Text(i18n.KeySayNameRule), true)
		return nil
	}
	m.pop()
	return m.runTool(source.ToolAdd, name)
}
