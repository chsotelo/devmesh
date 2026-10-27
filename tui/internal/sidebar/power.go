package sidebar

import (
	"context"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// Ids of the rows of the power menu.
const (
	powerSuspendID = "suspend"
	powerOffID     = "off"
	powerWakeID    = "wake"
	powerConfirmID = "confirm"
	powerCancelID  = "cancel"
	powerGlyph     = "⏻"
)

// powerState is the power menu: what dm allows on this machine, and the second step that
// powering off asks for.
type powerState struct {
	loading bool
	checked bool
	allowed source.PowerState
	confirm bool
}

type powerCheckMsg struct {
	state source.PowerState
	err   error
}

type powerDoneMsg struct {
	action string
	err    error
}

// openPower shows the power menu and asks dm what may be done to this machine.
func (m *Model) openPower() tea.Cmd {
	m.goMode(modePower)
	m.power = powerState{loading: true}
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), claudeBudget)
		defer cancel()
		state, err := src.PowerCheck(ctx, host)
		return powerCheckMsg{state: state, err: err}
	}
}

func (m *Model) applyPowerCheck(msg powerCheckMsg) {
	if m.claude.mode != modePower {
		return
	}
	m.power.loading = false
	if msg.err != nil {
		m.err = errorText(msg.err)
		return
	}
	m.power.checked, m.power.allowed = true, msg.state
}

// powerItems are the allowed actions; powering off is first asked to be confirmed.
func (m *Model) powerItems() []citem {
	if m.power.confirm {
		return []citem{
			{id: powerConfirmID, title: m.cat.Text(i18n.KeyPwConfirmYes)},
			{id: powerCancelID, title: m.cat.Text(i18n.KeyPwCancel)},
		}
	}
	items := []citem{}
	allowed := m.power.allowed
	if allowed.Suspend {
		items = append(items, citem{id: powerSuspendID, title: m.cat.Text(i18n.KeyPwSuspend)})
	}
	if allowed.Off {
		items = append(items, citem{id: powerOffID, title: m.cat.Text(i18n.KeyPwOff)})
	}
	if allowed.Wake {
		items = append(items, citem{id: powerWakeID, title: m.cat.Text(i18n.KeyPwWake)})
	}
	return items
}

// powerHead is the back line and, while confirming, the warning.
func (m *Model) powerHead() []cline {
	head := []cline{m.backLine(m.cat.Format(i18n.KeyPwMenu, m.host)), plain("")}
	if !m.power.confirm {
		return head
	}
	warning := m.cat.Format(i18n.KeyPwConfirmOff, m.host)
	for _, line := range strings.Split(ansi.Wordwrap(warning, max(m.width-indent, 1), ""), "\n") {
		head = append(head, plain(space+theme.Error().Render(m.fit(line, m.width-1))))
	}
	return append(head, plain(""))
}

// powerReason is what the empty menu says: checking, or why nothing is allowed.
func (m *Model) powerReason() string {
	if m.power.loading {
		return m.cat.Text(i18n.KeyPwChecking)
	}
	reasons := map[string]string{
		"other-lan":   i18n.KeyPwWhyOtherLan,
		"no-relay":    i18n.KeyPwWhyNoRelay,
		"no-mac":      i18n.KeyPwWhyNoMac,
		"no-wol":      i18n.KeyPwWhyNoWol,
		"outdated":    i18n.KeyPwWhyOutdated,
		"no-power":    i18n.KeyPwWhyNoPower,
		"unsupported": i18n.KeyPwWhyUnsupport,
	}
	if key, known := reasons[m.power.allowed.Why]; known && m.power.checked {
		return m.cat.Text(key)
	}
	return m.cat.Text(i18n.KeyPwNone)
}

// pickPower runs a row of the power menu.
func (m *Model) pickPower(id string) tea.Cmd {
	switch id {
	case powerSuspendID:
		return m.runPower(source.PowerSuspend)
	case powerWakeID:
		return m.runPower(source.PowerWake)
	case powerOffID:
		m.power.confirm, m.claude.cur, m.claude.top = true, 0, 0
	case powerConfirmID:
		return m.runPower(source.PowerOff)
	case powerCancelID:
		return m.goMode(modeClaude)
	}
	return nil
}

// powerShortcut are the keys of the power menu: only moving, never the session shortcuts.
func (m *Model) powerShortcut(name string) tea.Cmd {
	switch name {
	case "j":
		m.moveClaude(1)
	case "k":
		m.moveClaude(-1)
	case " ":
		return m.activate(m.cursorIndex(m.items()))
	}
	return nil
}

func (m *Model) runPower(action string) tea.Cmd {
	if m.claude.busy {
		return nil
	}
	m.claude.busy = true
	m.claude.note = m.cat.Text(i18n.KeyClWait)
	host, src := m.host, m.src
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), claudeBudget)
		defer cancel()
		return powerDoneMsg{action: action, err: src.Power(ctx, host, action)}
	}
}

// applyPowerDone reports the failure, or goes back to the sessions and says what was asked.
func (m *Model) applyPowerDone(msg powerDoneMsg) tea.Cmd {
	m.claude.busy = false
	m.claude.note = ""
	if msg.err != nil {
		m.err = errorText(msg.err)
		return m.goMode(modeClaude)
	}
	m.err = ""
	cmd := m.goMode(modeClaude)
	keys := map[string]string{
		source.PowerSuspend: i18n.KeyPwDoneSuspend,
		source.PowerOff:     i18n.KeyPwDoneOff,
		source.PowerWake:    i18n.KeyPwDoneWake,
	}
	m.claude.note = m.cat.Format(keys[msg.action], m.host)
	return tea.Batch(cmd, m.startPoll())
}
