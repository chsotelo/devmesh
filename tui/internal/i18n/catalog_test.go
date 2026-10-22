package i18n

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const catalogDir = "../../../client/lib/i18n"

func TestParseReadsKeyValueLinesAndIgnoresNoise(t *testing.T) {
	catalog := Parse("M_ACT_NEW=New terminal\nnot a catalog line\nOTHER=x\nM_WITH_EQUALS=a=b\n")

	if got := catalog.Text(KeyActNew); got != "New terminal" {
		t.Fatalf("Text = %q", got)
	}
	if got := catalog.Text("M_WITH_EQUALS"); got != "a=b" {
		t.Fatalf("value with = lost: %q", got)
	}
	if got := catalog.Text("OTHER"); got != "OTHER" {
		t.Fatalf("non-catalog key must come back as the key, got %q", got)
	}
}

func TestFormatFillsPlaceholdersInOrderAndExpandsEscapes(t *testing.T) {
	catalog := Parse(`M_A=%s · %s\n100%%` + "\n")

	got := catalog.Format("M_A", "one", "two")

	if got != "one · two\n100%" {
		t.Fatalf("Format = %q", got)
	}
	if missing := catalog.Format("M_A", "only"); missing != "only · \n100%" {
		t.Fatalf("missing argument = %q", missing)
	}
}

func TestCountPicksOneOrMany(t *testing.T) {
	catalog := Parse("M_ONE=%s terminal\nM_MANY=%s terminals\n")

	if got := catalog.Count(1, "M_ONE", "M_MANY"); got != "1 terminal" {
		t.Fatalf("one = %q", got)
	}
	if got := catalog.Count(0, "M_ONE", "M_MANY"); got != "0 terminals" {
		t.Fatalf("zero = %q", got)
	}
}

func TestWithFallbackKeepsTranslationsAndFillsGaps(t *testing.T) {
	catalog := Parse("M_ACT_NEW=Nueva terminal\n").WithFallback()

	if got := catalog.Text(KeyActNew); got != "Nueva terminal" {
		t.Fatalf("translation lost: %q", got)
	}
	if got := catalog.Text(KeyActQuit); got != "Quit" {
		t.Fatalf("fallback = %q", got)
	}
}

func TestParseCleansEscapesFromTranslations(t *testing.T) {
	catalog := Parse("M_ACT_NEW=\x1b[31mred\x1b[0m\n")

	if got := catalog.Text(KeyActNew); got != "red" {
		t.Fatalf("Text = %q", got)
	}
}

// shellValue reads the value of KEY=... from a catalog file (single quoted, with the
// usual quote-escape sequence for embedded quotes).
func shellValue(t *testing.T, file, key string) (string, bool) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(catalogDir, file))
	if err != nil {
		t.Fatalf("read %s: %v", file, err)
	}
	prefix := key + "='"
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.HasPrefix(line, prefix) {
			value := strings.TrimSuffix(strings.TrimPrefix(line, prefix), "'")
			return strings.ReplaceAll(value, `'\''`, "'"), true
		}
	}
	return "", false
}

func TestEmbeddedEnglishMatchesTheShellCatalog(t *testing.T) {
	for _, key := range Keys() {
		want, found := shellValue(t, "en.sh", key)
		if !found {
			t.Fatalf("%s is not in en.sh", key)
		}
		if got := english[key]; got != want {
			t.Fatalf("%s: fallback %q differs from en.sh %q (run scripts/gen-tui-fallback.sh)", key, got, want)
		}
	}
}

func TestSpanishCatalogTranslatesEveryPanelKey(t *testing.T) {
	for _, key := range Keys() {
		if _, found := shellValue(t, "es.sh", key); !found {
			t.Errorf("%s is missing from es.sh", key)
		}
	}
}
