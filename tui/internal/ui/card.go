package ui

import (
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

const (
	cardBorderRows  = 2
	cardHeaderRows  = 3
	cardPaddingCols = 4
	localOrigin     = "local"
	emptyThumbMark  = "…"
)

// cardSpec is everything a terminal card needs to be drawn.
type cardSpec struct {
	term     feed.Terminal
	selected bool
	width    int
	body     int
	thumb    []string
	now      time.Time
	cat      i18n.Catalog
}

// cardHeight is the total height of a card with body thumbnail lines.
func cardHeight(body int) int { return cardBorderRows + cardHeaderRows + body }

// stateLabel is the translated word of an agent state, empty for none.
func stateLabel(cat i18n.Catalog, state feed.AgentState) string {
	switch state {
	case feed.AgentWorking:
		return cat.Text(i18n.KeyStateWorking)
	case feed.AgentWaiting:
		return cat.Text(i18n.KeyStateWaiting)
	case feed.AgentIdle:
		return cat.Text(i18n.KeyStateIdle)
	default:
		return ""
	}
}

// stateBadge is the colored "● working" marker; plain dot for terminals without an agent.
func stateBadge(cat i18n.Catalog, state feed.AgentState) string {
	color := lipgloss.NewStyle().Foreground(theme.StateColor(state))
	label := stateLabel(cat, state)
	if label == "" {
		return ""
	}
	return color.Render(theme.Dot + space + label)
}

func originText(term feed.Terminal) string {
	if term.Origin == "" || term.Origin == localOrigin {
		return ""
	}
	return term.Origin
}

// cardRule is the separator under the header, labeled with the attached clients.
func cardRule(clients string, width int) string {
	rule := theme.Faint()
	if clients == "" {
		return rule.Render(strings.Repeat(ruleGlyph, width))
	}
	label := truncate(clients, max(width-6, 1))
	tail := max(width-cellWidth(label)-4, 0)
	return rule.Render(ruleGlyph+ruleGlyph+space) + theme.Dim().Render(label) +
		rule.Render(space+strings.Repeat(ruleGlyph, tail))
}

// thumbLines are the last body lines of the screen, cut to the card and dimmed.
func thumbLines(lines []string, body, width int) []string {
	out := make([]string, 0, body)
	if len(lines) == 0 {
		return append(out, theme.Faint().Render(emptyThumbMark))
	}
	for _, line := range feed.LastLines(lines, body) {
		out = append(out, theme.Dim().Render(truncate(line, width)))
	}
	return out
}

// renderCard draws one terminal card: name and state, command and origin, the clients rule
// and the last lines of its live screen.
func renderCard(spec cardSpec) string {
	inner := spec.width - cardPaddingCols
	term := spec.term
	title := theme.Bold().Render(term.Title())
	if spec.selected {
		title = theme.Accent().Bold(true).Render(term.Title())
	}
	first := spread(title, stateBadge(spec.cat, term.Agent), inner)
	details := []string{term.Command}
	if origin := originText(term); origin != "" {
		details = append(details, origin)
	}
	second := spread(theme.Dim().Render(strings.Join(details, middleDot)),
		theme.Dim().Render(ago(spec.now, term.Activity)), inner)
	rows := []string{first, second, cardRule(term.Clients, inner)}
	rows = append(rows, fitLines(thumbLines(spec.thumb, spec.body, inner), spec.body)...)
	return theme.Card(spec.selected, spec.width).Padding(0, 1).Render(strings.Join(rows, newline))
}
