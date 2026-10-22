// Package i18n reads the message catalog that "dm _i18n" prints, so the panel speaks the
// same language as the rest of dm.
package i18n

import (
	"bufio"
	"strconv"
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

const (
	keyPrefix   = "M_"
	assignSep   = "="
	placeholder = "%s"
	escapedPerc = "%%"
	literalNL   = `\n`
	newline     = "\n"
	percent     = "%"
)

// Catalog maps a message key (M_ACT_NEW) to its format string.
type Catalog struct {
	messages map[string]string
}

// Parse reads KEY=VALUE lines. Lines that are not catalog entries are ignored.
func Parse(raw string) Catalog {
	messages := map[string]string{}
	scanner := bufio.NewScanner(strings.NewReader(raw))
	for scanner.Scan() {
		key, value, found := strings.Cut(scanner.Text(), assignSep)
		if !found || !strings.HasPrefix(key, keyPrefix) {
			continue
		}
		messages[key] = feed.Clean(value)
	}
	return Catalog{messages: messages}
}

// Fallback returns the embedded English catalog.
func Fallback() Catalog {
	messages := make(map[string]string, len(english))
	for key, value := range english {
		messages[key] = value
	}
	return Catalog{messages: messages}
}

// WithFallback fills the keys this catalog lacks from the embedded English one.
func (c Catalog) WithFallback() Catalog {
	merged := make(map[string]string, len(english)+len(c.messages))
	for key, value := range english {
		merged[key] = value
	}
	for key, value := range c.messages {
		merged[key] = value
	}
	return Catalog{messages: merged}
}

// Text returns the message with its escapes expanded, or the key when it is unknown.
func (c Catalog) Text(key string) string {
	value, found := c.messages[key]
	if !found {
		return key
	}
	return strings.ReplaceAll(value, literalNL, newline)
}

// Format fills the %s placeholders of a message, in order.
func (c Catalog) Format(key string, args ...string) string {
	text := c.Text(key)
	var out strings.Builder
	next := 0
	for i := 0; i < len(text); i++ {
		switch {
		case strings.HasPrefix(text[i:], escapedPerc):
			out.WriteString(percent)
			i++
		case strings.HasPrefix(text[i:], placeholder):
			if next < len(args) {
				out.WriteString(args[next])
				next++
			}
			i++
		default:
			out.WriteByte(text[i])
		}
	}
	return out.String()
}

// Count formats "1 terminal" / "3 terminals" with the one/many keys.
func (c Catalog) Count(total int, oneKey, manyKey string) string {
	key := manyKey
	if total == 1 {
		key = oneKey
	}
	return c.Format(key, strconv.Itoa(total))
}

// Keys lists the keys of the embedded English catalog (used by tests).
func Keys() []string {
	keys := make([]string, 0, len(english))
	for key := range english {
		keys = append(keys, key)
	}
	return keys
}
