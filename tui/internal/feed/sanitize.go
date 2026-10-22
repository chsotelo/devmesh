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
	if r == unicode.ReplacementChar {
		return true
	}
	return unicode.IsControl(r) || unicode.Is(unicode.Cf, r)
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
