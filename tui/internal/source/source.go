// Package source is the only door to the outside world: every remote or sensitive operation
// goes through the bash "dm" command, called with an argument vector (never a shell string).
package source

import (
	"context"
	"os/exec"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// Reader reads what the panel shows.
type Reader interface {
	Feed(ctx context.Context) (feed.Snapshot, error)
	Shot(ctx context.Context, host, session, window string) ([]string, error)
	Projects(ctx context.Context, host string) ([]string, error)
	Devices(ctx context.Context) (string, error)
}

// Actor runs actions that need no terminal: they print nothing the user must read.
type Actor interface {
	Open(ctx context.Context, host, session, window string) error
	Create(ctx context.Context, host, name, project string) error
	Validate(ctx context.Context, host, name, project string) error
	Refresh(ctx context.Context) error
}

// Foreground builds the commands that take over the screen (attach, pickers, QR codes);
// the caller runs them with tea.ExecProcess.
type Foreground interface {
	OpenCommand(host, session, window string) *exec.Cmd
	CreateCommand(host, name, project string) *exec.Cmd
	ToolCommand(tool string, args ...string) *exec.Cmd
}

// Source is everything the panel needs from dm.
type Source interface {
	Reader
	Actor
	Foreground
}

// Tools that run full screen through "dm _app run".
const (
	ToolSend    = "send"
	ToolFetch   = "fetch"
	ToolPort    = "port"
	ToolDevices = "devices"
	ToolAdd     = "add"
	ToolWake    = "wake"
)
