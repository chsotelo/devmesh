package source

import (
	"errors"
	"regexp"
	"strings"
	"unicode"
)

// ErrInvalidArgument is returned before anything is executed when an argument would not be
// accepted by dm anyway (this keeps hostile names out of the command line).
var ErrInvalidArgument = errors.New("invalid argument")

const maxNameRunes = 64

var (
	hostPattern    = regexp.MustCompile(`^[a-z][a-z0-9-]{0,15}$`)
	sessionPattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_-]{0,29}$`)
	windowPattern  = regexp.MustCompile(`^([0-9]{1,5})?$`)
	projectPattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$`)
)

// ValidHost reports whether name looks like a device name.
func ValidHost(name string) bool { return hostPattern.MatchString(name) }

// ValidSession reports whether name is a tmux session dm would accept.
func ValidSession(name string) bool { return sessionPattern.MatchString(name) }

// ValidProject reports whether name is a plain project folder name.
func ValidProject(name string) bool { return projectPattern.MatchString(name) }

func validWindow(window string) bool { return windowPattern.MatchString(window) }

// ValidDeviceName follows the rule of "dm add".
func ValidDeviceName(name string) bool {
	return hostPattern.MatchString(name) && !strings.HasPrefix(name, "hub") && !strings.HasSuffix(name, "-b")
}

// validFreeName accepts what a person types as a terminal name: dm sanitizes it afterwards.
func validFreeName(name string) bool {
	if name == "" || len([]rune(name)) > maxNameRunes {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func checkOpenArguments(host, session, window string) error {
	if !ValidHost(host) || !ValidSession(session) || !validWindow(window) {
		return ErrInvalidArgument
	}
	return nil
}

func checkCreateArguments(host, name, project string) error {
	if !ValidHost(host) || !validFreeName(name) {
		return ErrInvalidArgument
	}
	if project != "" && !ValidProject(project) {
		return ErrInvalidArgument
	}
	return nil
}
