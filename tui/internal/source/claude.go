package source

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// claudeTimeout is longer than the other actions: stopping waits for the process to end and
// moving copies the transcript to the other machine.
const claudeTimeout = 120 * time.Second

// Words of the dm commands that act on Claude Code sessions (controller side: dm runs them
// on the machine through its own transport).
const (
	cmdClaudeStop   = "_cstop"
	cmdClaudeResume = "_cresume"
	cmdClaudeNew    = "_cnew"
	cmdClaudeMove   = "_cmove"
)

var errNoSessionName = errors.New("dm did not say which session to open")

// StopClaude stops a running session: "dm _cstop HOST SESSION_ID".
func (d *Dm) StopClaude(ctx context.Context, host, sessionID string) error {
	if !ValidHost(host) || !ValidSessionID(sessionID) {
		return ErrInvalidArgument
	}
	_, err := d.output(ctx, claudeTimeout, cmdClaudeStop, host, sessionID)
	return err
}

// ResumeClaude resumes a stopped session on its machine: "dm _cresume HOST SESSION_ID".
func (d *Dm) ResumeClaude(ctx context.Context, host, sessionID string) (string, error) {
	if !ValidHost(host) || !ValidSessionID(sessionID) {
		return "", ErrInvalidArgument
	}
	return d.sessionName(ctx, cmdClaudeResume, host, sessionID)
}

// NewClaude starts a session in a project folder: "dm _cnew HOST NAME proj:FOLDER".
func (d *Dm) NewClaude(ctx context.Context, host, name, project string) (string, error) {
	if !ValidHost(host) || !validFreeName(name) || !ValidProject(project) {
		return "", ErrInvalidArgument
	}
	return d.sessionName(ctx, cmdClaudeNew, host, name, projectSpec+project)
}

// MoveClaude moves a session to another machine: "dm _cmove SRC SESSION_ID DST".
func (d *Dm) MoveClaude(ctx context.Context, from, sessionID, to string) (string, error) {
	if !ValidHost(from) || !ValidHost(to) || from == to || !ValidSessionID(sessionID) {
		return "", ErrInvalidArgument
	}
	return d.sessionName(ctx, cmdClaudeMove, from, sessionID, to)
}

// sessionName runs a command that prints the tmux session to open (its last line).
func (d *Dm) sessionName(ctx context.Context, args ...string) (string, error) {
	out, err := d.output(ctx, claudeTimeout, args...)
	if err != nil {
		return "", err
	}
	lines := feed.TrimBlank(feed.CleanLines(out))
	if len(lines) == 0 {
		return "", errNoSessionName
	}
	name := strings.TrimSpace(lines[len(lines)-1])
	if !ValidSession(name) {
		return "", errNoSessionName
	}
	return name, nil
}
