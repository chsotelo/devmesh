package feed

import (
	"strings"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

const (
	tabSpaces = "    "
	tabRune   = "\t"
	crRune    = "\r"
	lfRune    = "\n"

	c1Start          = 0x80
	c1End            = 0x9F
	lrmRune          = 0x200E
	rlmRune          = 0x200F
	bidiEmbedStart   = 0x202A
	bidiEmbedEnd     = 0x202E
	bidiIsolateStart = 0x2066
	bidiIsolateEnd   = 0x2069
)

// Clean removes everything a remote machine could use to move the cursor, recolor the
// screen or spoof text: escape sequences, control characters and bidi/format characters.
func Clean(raw string) string {
	stripped := ansi.Strip(raw)
	var out strings.Builder
	out.Grow(len(stripped))
	for _, r := range stripped {
		if isUnsafeRune(r) {
			continue
		}
		out.WriteRune(r)
	}
	return out.String()
}

func isUnsafeRune(r rune) bool {
	if r == unicode.ReplacementChar || isC1Control(r) || isBidiControl(r) {
		return true
	}
	return unicode.IsControl(r) || unicode.Is(unicode.Cf, r)
}

// isC1Control: U+0080-U+009F, which some terminals read as escape-sequence introducers.
func isC1Control(r rune) bool {
	return r >= c1Start && r <= c1End
}

// isBidiControl: the marks and overrides that reorder text on screen (spoofing).
func isBidiControl(r rune) bool {
	switch {
	case r == lrmRune || r == rlmRune:
		return true
	case r >= bidiEmbedStart && r <= bidiEmbedEnd:
		return true
	case r >= bidiIsolateStart && r <= bidiIsolateEnd:
		return true
	}
	return false
}

// CleanLines cleans multi-line text: tabs become spaces, other controls are dropped.
func CleanLines(raw string) []string {
	text := strings.ReplaceAll(raw, crRune, "")
	text = strings.ReplaceAll(text, tabRune, tabSpaces)
	lines := strings.Split(text, lfRune)
	cleaned := make([]string, 0, len(lines))
	for _, line := range lines {
		cleaned = append(cleaned, Clean(line))
	}
	return cleaned
}

// TrimBlank drops the empty lines at the end and the start of a screen.
func TrimBlank(lines []string) []string {
	start, end := 0, len(lines)
	for start < end && strings.TrimSpace(lines[start]) == "" {
		start++
	}
	for end > start && strings.TrimSpace(lines[end-1]) == "" {
		end--
	}
	return lines[start:end]
}

// LastLines keeps the last count lines.
func LastLines(lines []string, count int) []string {
	if count < 0 {
		count = 0
	}
	if len(lines) <= count {
		return lines
	}
	return lines[len(lines)-count:]
}
