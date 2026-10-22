package ui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
)

// assertFits checks the frame is exactly width x height cells: nothing wraps or overflows.
func assertFits(t *testing.T, m *Model, width, height int) {
	t.Helper()
	lines := viewLines(m)
	if len(lines) != height {
		t.Fatalf("%dx%d: %d lines, want %d", width, height, len(lines), height)
	}
	for i, line := range lines {
		if got := cellWidth(line); got > width {
			t.Fatalf("%dx%d: line %d is %d cells wide: %q", width, height, i, got, line)
		}
	}
}

func TestColumnsFollowTheWidth(t *testing.T) {
	cases := map[int]int{45: 1, 60: 1, 70: 2, 88: 2, 106: 3, 140: 4, 300: 4}
	for width, want := range cases {
		if got := columnsFor(width); got != want {
			t.Errorf("columnsFor(%d) = %d, want %d", width, got, want)
		}
	}
}

func TestCardWidthsShareTheRemainder(t *testing.T) {
	widths := cardWidths(70, 2)

	if widths[0]+widths[1]+cardGap != 70 {
		t.Fatalf("widths %v do not fill 70 cells", widths)
	}
}

func TestThumbnailHeightAdaptsToTheRoom(t *testing.T) {
	if got := bodyLinesFor(10); got != minThumbLines {
		t.Fatalf("small screen = %d, want %d", got, minThumbLines)
	}
	if got := bodyLinesFor(200); got != maxThumbLines {
		t.Fatalf("huge screen = %d, want %d", got, maxThumbLines)
	}
	if bodyLinesFor(27) > bodyLinesFor(47) {
		t.Fatal("more room must never mean fewer thumbnail lines")
	}
}

func TestPhoneShowsOneColumnOfCards(t *testing.T) {
	m, _ := newTestModel(t, 45, 30, true)

	assertFits(t, m, 45, 30)
	lines := viewLines(m)
	for _, line := range lines {
		if strings.Count(line, "╭") > 1 {
			t.Fatalf("two cards side by side on a phone: %q", line)
		}
	}
	text := m.View()
	for _, want := range []string{"devmesh 0.9.0", "[new]", "laptop", "api", "waiting", "claude · tablet", "Edit src/auth.ts?", "1 waiting"} {
		if !strings.Contains(text, want) {
			t.Errorf("phone view lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "live screen") {
		t.Error("the detail pane must not appear on a phone")
	}
}

func TestPortraitTabletShowsTwoColumnsAndFillsTheScreen(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)

	assertFits(t, m, 70, 50)
	sideBySide := false
	for _, line := range viewLines(m) {
		sideBySide = sideBySide || strings.Count(line, "╭") == 2
	}
	if !sideBySide {
		t.Fatalf("expected two cards per row at 70 columns:\n%s", m.View())
	}
	text := m.View()
	for _, want := range []string{"[send]", "[fetch]", "[devices]", "web", "docs", "working", "enter open", "tablet · 3 machines · 3 terminals · 1 waiting"} {
		if !strings.Contains(text, want) {
			t.Errorf("tablet view lacks %q:\n%s", want, text)
		}
	}
	if !strings.Contains(text, "Writing docs/guide.md...") {
		t.Error("the thumbnail of the third terminal is missing")
	}
}

func TestWideScreenAddsTheDetailPaneWithTheLiveScreen(t *testing.T) {
	m, _ := newTestModel(t, 160, 45, true)

	assertFits(t, m, 160, 45)
	text := m.View()
	for _, want := range []string{"live screen", "[open]", "[send file]", "Edit src/auth.ts?"} {
		if !strings.Contains(text, want) {
			t.Errorf("wide view lacks %q:\n%s", want, text)
		}
	}
	if got := columnsFor(160 - 160*45/100 - cardGap); got != 2 {
		t.Errorf("cards beside the detail pane use %d columns, want 2", got)
	}
}

func TestOfflineAndEmptyMachinesExplainThemselves(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)

	text := m.View()

	for _, want := range []string{"desktop", "offline", "[wake]", "off or unreachable", "pc2", "no terminals yet · press n to create one"} {
		if !strings.Contains(text, want) {
			t.Errorf("view lacks %q:\n%s", want, text)
		}
	}
}

func TestEmptyMeshShowsTheFriendlyCardWithAnAddButton(t *testing.T) {
	m, fake := newTestModel(t, 70, 30, true)
	fake.snapshot = feed.Snapshot{Device: "tablet", Version: "0.9.0"}
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	text := m.View()

	for _, want := range []string{"No machines yet.", "Terminals live on your Linux or Mac machines.", "[add device]"} {
		if !strings.Contains(text, want) {
			t.Errorf("empty state lacks %q:\n%s", want, text)
		}
	}
	hitFor(t, m, intent{verb: verbAdd})
	assertFits(t, m, 70, 30)
}

func TestBeforeTheFirstReadingItSaysLoading(t *testing.T) {
	m := New(Options{Source: &fakeSource{}, Catalog: i18n.Fallback(), Now: func() time.Time { return fixedNow }})
	m.Update(tea.WindowSizeMsg{Width: 70, Height: 20})

	if !strings.Contains(m.View(), "loading…") {
		t.Fatalf("view:\n%s", m.View())
	}
	m.Update(feedMsg{seq: m.feedSeq, err: errFeedDown})
	if text := m.View(); !strings.Contains(text, "could not read the machines") || !strings.Contains(text, "hub unreachable") {
		t.Fatalf("failed first reading:\n%s", text)
	}
}

func TestATinyWindowAsksForMoreRoom(t *testing.T) {
	m, _ := newTestModel(t, 20, 8, true)

	if !strings.Contains(m.View(), "window too small") {
		t.Fatalf("view:\n%s", m.View())
	}
	assertFits(t, m, 20, 8)
}

func TestHostileFeedTextNeverReachesTheScreen(t *testing.T) {
	m, fake := newTestModel(t, 70, 40, true)
	fake.snapshot = feed.Parse("V\t0.9.0\ttablet\nM\tlaptop\tOK\t33\t10.0.0.2\t-\t-\n" +
		"T\tlaptop\tapi\t1\tn\t1\t\x1b[2Jclaude\x1b]0;x\x07\twaiting\tev\x1bil\t1700000000\t1700000000\t\x1b[31mbob\n")
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	text := m.View()

	if strings.Contains(text, "\x1b") {
		t.Fatalf("escape sequence leaked into the view: %q", text)
	}
	if !strings.Contains(text, "claude") {
		t.Fatalf("the cleaned command is missing:\n%s", text)
	}
}

func TestLongThumbnailLinesAreCutNotWrapped(t *testing.T) {
	m, _ := newTestModel(t, 45, 30, true)
	m.shots["laptop/api/1"] = shot{lines: []string{strings.Repeat("x", 300), "日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語"}, at: fixedNow}

	assertFits(t, m, 45, 30)
	if !strings.Contains(m.View(), "…") {
		t.Fatal("a cut line must end with an ellipsis")
	}
}

func TestMachineSectionsHaveStableCells(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)

	layout := m.homeLayout()

	if len(layout.cells) != 6 {
		t.Fatalf("cells = %d, want 3 headers + 3 cards", len(layout.cells))
	}
	if layout.cells[0].key != machineKey("laptop") || layout.cells[1].key != "t:laptop/api/1" {
		t.Fatalf("cell order: %v %v", layout.cells[0].key, layout.cells[1].key)
	}
}

func TestFilterShowsOnlyMatchingTerminals(t *testing.T) {
	m, _ := newTestModel(t, 70, 50, true)

	press(m, "/")
	typeText(m, "docs")
	text := m.View()

	if !strings.Contains(text, "docs") || strings.Contains(text, "│ web") {
		t.Fatalf("filter did not narrow the cards:\n%s", text)
	}
	if strings.Contains(text, "desktop") {
		t.Fatal("machines without matches are hidden while filtering")
	}
	if !strings.Contains(text, "filter") {
		t.Fatalf("the input box must show while filtering:\n%s", text)
	}
}

func TestSpanishCatalogTranslatesTheTopBar(t *testing.T) {
	m, fake := newTestModel(t, 70, 30, true)
	m.cat = i18n.Parse("M_WORD_NEW=nueva\nM_WORD_SEND=enviar\nM_STATE_WAITING=esperando\n").WithFallback()
	m.Update(feedMsg{seq: m.feedSeq, snap: fake.snapshot})

	text := m.View()

	for _, want := range []string{"[nueva]", "[enviar]", "esperando"} {
		if !strings.Contains(text, want) {
			t.Errorf("translated view lacks %q:\n%s", want, text)
		}
	}
}
