package ui

import (
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
	"github.com/chsotelo/devmesh/tui/internal/theme"
)

// Sizes and rhythms of the panel.
const (
	defaultWidth    = 80
	defaultHeight   = 24
	minWidth        = 30
	minHeight       = 10
	feedEvery       = 4 * time.Second
	shotEvery       = 3 * time.Second
	noticeLifetime  = 6 * time.Second
	maxInputRunes   = 64
	inputBoxHeight  = 3
	topBarHeight    = 1
	bottomBarHeight = 2
	wideDetailWidth = 140
	wheelStep       = 3
	feedBudget      = 35 * time.Second
	shotBudget      = 15 * time.Second
	actionBudget    = 40 * time.Second
	listBudget      = 20 * time.Second
)

// Options are what the panel needs from the outside.
type Options struct {
	Source  source.Source
	Catalog i18n.Catalog
	InTmux  bool
	Version string
	Now     func() time.Time
}

// shot is the last live screen read from a terminal.
type shot struct {
	lines []string
	at    time.Time
}

// Model is the Bubble Tea model of the whole panel.
type Model struct {
	src     source.Source
	cat     i18n.Catalog
	inTmux  bool
	version string
	now     func() time.Time

	width  int
	height int
	routes []route

	snap     feed.Snapshot
	loaded   bool
	feedErr  string
	feedSeq  int
	feedBusy bool

	shots       map[string]shot
	inflight    map[string]int
	shotCounter int

	selected string
	scroll   int
	filter   textinput.Model
	filterOn bool
	input    textinput.Model
	cursor   int

	projects     map[string][]string
	projectsHost string
	devicesText  string
	devicesErr   string
	devicesBusy  bool

	notice      string
	noticeError bool
	noticeUntil time.Time

	claudeHost   string
	claudeSel    string
	claudeScroll int
	claudeBusy   bool

	lastIntent intent
	finished   bool
}

// New builds the model; Init starts the first reading.
func New(options Options) *Model {
	now := options.Now
	if now == nil {
		now = time.Now
	}
	m := &Model{
		src:      options.Source,
		cat:      options.Catalog,
		inTmux:   options.InTmux,
		version:  options.Version,
		now:      now,
		width:    defaultWidth,
		height:   defaultHeight,
		routes:   []route{{screen: screenHome}},
		shots:    map[string]shot{},
		inflight: map[string]int{},
		projects: map[string][]string{},
	}
	m.filter = newInput(m.cat.Text(i18n.KeyGhostSearch))
	m.input = newInput("")
	return m
}

func newInput(placeholder string) textinput.Model {
	field := textinput.New()
	field.Prompt = pointer
	field.Placeholder = placeholder
	field.CharLimit = maxInputRunes
	field.PromptStyle = theme.Bold()
	field.TextStyle = theme.Text()
	field.PlaceholderStyle = theme.Faint()
	field.Cursor.Style = theme.Accent()
	return field
}

// Init starts the first feed reading and the two refresh rhythms.
func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.fetchFeed(), feedTick(), shotTick())
}

// Finished reports whether the user asked to quit.
func (m *Model) Finished() bool { return m.finished }

func (m *Model) top() route { return m.routes[len(m.routes)-1] }

func (m *Model) push(next route) {
	m.routes = append(m.routes, next)
	m.cursor = 0
}

func (m *Model) pop() {
	if len(m.routes) > 1 {
		m.routes = m.routes[:len(m.routes)-1]
	}
	m.cursor = 0
	m.input.Blur()
	m.input.SetValue("")
}

// typing reports whether the keyboard goes to a text input.
func (m *Model) typing() bool {
	switch current := m.top().screen; current {
	case screenNewProject, screenAdd:
		return true
	case screenTerminals:
		return m.filterOn
	default:
		return hasTextInput(current)
	}
}

// wide reports whether the detail pane fits next to the cards.
func (m *Model) wide() bool { return m.width >= wideDetailWidth }

func (m *Model) say(text string, isError bool) {
	m.notice = text
	m.noticeError = isError
	m.noticeUntil = m.now().Add(noticeLifetime)
}

func (m *Model) activeNotice() (string, bool) {
	if m.notice == "" || m.now().After(m.noticeUntil) {
		return "", false
	}
	return m.notice, m.noticeError
}
