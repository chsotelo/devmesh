package ui

import (
	"strings"
	"time"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	detailHeaderRows = 4
	detailFrameRows  = 2
	detailPadding    = 4
)

// detailSpec is what the detail view of one terminal shows.
type detailSpec struct {
	term   feed.Terminal
	screen []string
	width  int
	height int
	now    time.Time
	cat    i18n.Catalog
}

func detailButtons(spec detailSpec) []button {
	return []button{
		{label: spec.cat.Text(i18n.KeyWordOpen), act: intent{verb: verbOpenTerminal, arg: spec.term.Key()}},
		{label: spec.cat.Text(i18n.KeyWordSendFile), act: intent{verb: verbSend}},
		{label: spec.cat.Text(i18n.KeyWordWeb), act: intent{verb: verbWeb}},
	}
}

// detailInfo is the dim line under the title: where the terminal runs and who is attached.
func detailInfo(spec detailSpec) []string {
	term := spec.term
	where := []string{term.Host, term.Command}
	if origin := originText(term); origin != "" {
		where = append(where, spec.cat.Text(i18n.KeyLabelFrom)+space+origin)
	}
	activity := spec.cat.Text(i18n.KeyLabelActive) + space + ago(spec.now, term.Activity)
	if term.Clients != "" {
		activity += middleDot + spec.cat.Format(i18n.KeyAttached, term.Clients)
	}
	return []string{theme.Dim().Render(strings.Join(where, middleDot)), theme.Dim().Render(activity)}
}

// renderDetail draws the bordered detail of a terminal: header, big live screen and buttons.
func renderDetail(spec detailSpec) block {
	inner := spec.width - detailPadding
	term := spec.term
	rows := []string{spread(theme.Accent().Bold(true).Render(term.Title()), stateBadge(spec.cat, term.Agent), inner)}
	rows = append(rows, detailInfo(spec)...)
	rows = append(rows, theme.Faint().Render(ruleGlyph+space)+theme.Dim().Render(spec.cat.Text(i18n.KeyLiveScreen))+
		theme.Faint().Render(space+strings.Repeat(ruleGlyph, max(inner-cellWidth(spec.cat.Text(i18n.KeyLiveScreen))-3, 0))))
	room := max(spec.height-detailFrameRows-detailHeaderRows-1, 0)
	rows = append(rows, fitLines(thumbLines(spec.screen, room, inner), room)...)
	buttons, hits := layoutButtons(detailButtons(spec), detailX(), spec.height-detailFrameRows)
	rows = append(rows, buttons)
	framed := theme.Panel(spec.width).Padding(0, 1).Render(strings.Join(rows, newline))
	return block{lines: splitLines(framed), hits: hits}
}

// detailX is the column where the content of the frame starts (border + padding).
func detailX() int { return 2 }

// machineSummary is the detail pane when a machine header is selected.
func machineSummary(machine feed.Machine, width, height int, cat i18n.Catalog) block {
	inner := width - detailPadding
	rows := []string{
		spread(theme.Accent().Bold(true).Render(machine.Name), theme.MachineDot(machine.Color, machine.IsReachable()), inner),
		theme.Dim().Render(cat.Text(i18n.KeyLabelAddress) + space + machine.IP),
	}
	if machine.IsReachable() {
		rows = append(rows, theme.Dim().Render(cat.Count(len(machine.Terminals), i18n.KeyTerminalOne, i18n.KeyTerminalMany)))
	} else {
		rows = append(rows, theme.Dim().Render(cat.Text(i18n.KeyPreviewOffHelp)))
	}
	framed := theme.Panel(width).Padding(0, 1).Height(height - detailFrameRows).Render(strings.Join(rows, newline))
	return block{lines: splitLines(framed)}
}
