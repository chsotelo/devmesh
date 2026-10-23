package source

import (
	"context"
	"strings"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// Words of the workspace commands: "dm _ws <sub>" drives the tmux layout.
const (
	cmdWorkspace = "_ws"
	subShow      = "show"
	subHold      = "hold"
	subShown     = "shown"
	subAct       = "act"
	flagFocus    = "focus"
	// HoldEmpty and HoldOffline are the messages that can replace a terminal.
	HoldEmpty   = "empty"
	HoldOffline = "offline"
	// ActAdd and ActDelete are the buttons of the list: a new terminal, delete the shown one.
	ActAdd    = "add"
	ActDelete = "delete"
)

// FeedHost reads one machine with "dm _feed HOST".
func (d *Dm) FeedHost(ctx context.Context, host string) (feed.Snapshot, error) {
	if !ValidHost(host) {
		return feed.Snapshot{}, ErrInvalidArgument
	}
	out, err := d.output(ctx, feedTimeout, cmdFeed, host)
	if err != nil {
		return feed.Snapshot{}, err
	}
	return feed.Parse(out), nil
}

// Shown returns the session the right pane of a machine window is showing ("" for none).
func (d *Dm) Shown(ctx context.Context, host string) (string, error) {
	if !ValidHost(host) {
		return "", ErrInvalidArgument
	}
	out, err := d.output(ctx, actionTimeout, cmdWorkspace, subShown, host)
	if err != nil {
		return "", err
	}
	session := strings.TrimSpace(feed.Clean(out))
	if !ValidSession(session) {
		return "", nil
	}
	return session, nil
}

// PaneTarget is the terminal to show in the right pane; Focus also moves the keyboard there.
type PaneTarget struct {
	Host    string
	Session string
	Window  string
	Focus   bool
}

// Show puts a terminal in the right pane.
func (d *Dm) Show(ctx context.Context, target PaneTarget) error {
	if err := checkOpenArguments(target.Host, target.Session, target.Window); err != nil {
		return err
	}
	window := target.Window
	if window == "" {
		window = noWindow
	}
	arguments := []string{cmdWorkspace, subShow, target.Host, target.Session, window}
	if target.Focus {
		arguments = append(arguments, flagFocus)
	}
	_, err := d.output(ctx, actionTimeout, arguments...)
	return err
}

// Hold replaces the right pane with a message: HoldEmpty or HoldOffline.
func (d *Dm) Hold(ctx context.Context, host, kind string) error {
	if !ValidHost(host) || (kind != HoldEmpty && kind != HoldOffline) {
		return ErrInvalidArgument
	}
	_, err := d.output(ctx, actionTimeout, cmdWorkspace, subHold, host, kind)
	return err
}

// Act runs a button of the list of a machine: ActAdd or ActDelete.
func (d *Dm) Act(ctx context.Context, host, action string) error {
	if !ValidHost(host) || (action != ActAdd && action != ActDelete) {
		return ErrInvalidArgument
	}
	_, err := d.output(ctx, actionTimeout, cmdWorkspace, subAct, action, host)
	return err
}
