package source

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// Time allowed to each dm call before it is abandoned.
const (
	feedTimeout    = 30 * time.Second
	shotTimeout    = 12 * time.Second
	listTimeout    = 15 * time.Second
	actionTimeout  = 30 * time.Second
	maxOutputBytes = 2 * 1024 * 1024
)

// Words of the dm command line (internal sub-commands the panel relies on).
const (
	cmdFeed     = "_feed"
	cmdShot     = "_shot"
	cmdProjects = "_proj"
	cmdNew      = "_new"
	cmdApp      = "_app"
	cmdOpen     = "open"
	cmdRun      = "run"
	cmdDevices  = "devices"
	cmdRefresh  = "refresh"
	cmdI18n     = "_i18n"
	flagCheck   = "--check"
	noWindow    = "-"
	projectSpec = "proj:"
	envDmSelf   = "DM_SELF"
	envDmBash   = "DM_BASH"
	defaultBin  = "dm"
)

// Dm runs the dm command line.
type Dm struct {
	bin  string
	bash string
}

// NewDm returns a Source that calls the dm at bin; empty means $DM_SELF, then "dm" in PATH.
func NewDm(bin string) *Dm {
	if bin == "" {
		bin = os.Getenv(envDmSelf)
	}
	if bin == "" {
		bin = defaultBin
	}
	// dm is a bash script: run it through the bash that started us when known. On Termux
	// its "#!/usr/bin/env bash" line only works through termux-exec, which Go bypasses.
	return &Dm{bin: bin, bash: os.Getenv(envDmBash)}
}

// command is dm with these arguments, through bash when DM_BASH is set.
func (d *Dm) command(ctx context.Context, args ...string) *exec.Cmd {
	if d.bash != "" {
		return exec.CommandContext(ctx, d.bash, append([]string{d.bin}, args...)...)
	}
	return exec.CommandContext(ctx, d.bin, args...)
}

type cappedBuffer struct {
	data bytes.Buffer
}

func (b *cappedBuffer) Write(chunk []byte) (int, error) {
	room := maxOutputBytes - b.data.Len()
	if room > 0 {
		b.data.Write(chunk[:min(len(chunk), room)])
	}
	return len(chunk), nil
}

// output runs dm with the timeout and returns its stdout.
func (d *Dm) output(ctx context.Context, timeout time.Duration, args ...string) (string, error) {
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	command := d.command(callCtx, args...)
	var stdout, stderr cappedBuffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	command.WaitDelay = time.Second
	if err := command.Run(); err != nil {
		return stdout.data.String(), commandError(err, stderr.data.String())
	}
	return stdout.data.String(), nil
}

// commandError keeps the first useful line dm wrote to stderr, cleaned.
func commandError(err error, stderr string) error {
	for _, line := range feed.CleanLines(stderr) {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "error:"))
		if line != "" {
			return errors.New(line)
		}
	}
	return err
}

// Feed reads the whole mesh with "dm _feed".
func (d *Dm) Feed(ctx context.Context) (feed.Snapshot, error) {
	out, err := d.output(ctx, feedTimeout, cmdFeed)
	if err != nil {
		return feed.Snapshot{}, err
	}
	return feed.Parse(out), nil
}

// Shot reads the live screen of a terminal.
func (d *Dm) Shot(ctx context.Context, host, session, window string) ([]string, error) {
	if err := checkOpenArguments(host, session, window); err != nil {
		return nil, err
	}
	out, err := d.output(ctx, shotTimeout, cmdShot, host, session, window)
	if err != nil {
		return nil, err
	}
	return feed.TrimBlank(feed.CleanLines(out)), nil
}

// Projects lists the project folders of a machine.
func (d *Dm) Projects(ctx context.Context, host string) ([]string, error) {
	if !ValidHost(host) {
		return nil, ErrInvalidArgument
	}
	out, err := d.output(ctx, listTimeout, cmdProjects, host)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range feed.CleanLines(out) {
		if ValidProject(line) {
			names = append(names, line)
		}
	}
	return names, nil
}

// Devices returns the device list as text.
func (d *Dm) Devices(ctx context.Context) (string, error) {
	out, err := d.output(ctx, listTimeout, cmdDevices)
	if err != nil {
		return "", err
	}
	return strings.Join(feed.TrimBlank(feed.CleanLines(out)), "\n"), nil
}

// Open focuses (or creates) the tab of a terminal inside the tmux workspace.
func (d *Dm) Open(ctx context.Context, host, session, window string) error {
	if err := checkOpenArguments(host, session, window); err != nil {
		return err
	}
	_, err := d.output(ctx, actionTimeout, d.openArguments(host, session, window)...)
	return err
}

// Create validates the name in dm and opens the new terminal as a tab.
func (d *Dm) Create(ctx context.Context, host, name, project string) error {
	if err := checkCreateArguments(host, name, project); err != nil {
		return err
	}
	_, err := d.output(ctx, actionTimeout, createArguments(host, name, project)...)
	return err
}

// Validate runs the checks of Create without opening anything.
func (d *Dm) Validate(ctx context.Context, host, name, project string) error {
	if err := checkCreateArguments(host, name, project); err != nil {
		return err
	}
	arguments := append([]string{cmdNew, flagCheck}, createArguments(host, name, project)[1:]...)
	_, err := d.output(ctx, actionTimeout, arguments...)
	return err
}

// Refresh re-reads the device list from the hub.
func (d *Dm) Refresh(ctx context.Context) error {
	_, err := d.output(ctx, actionTimeout, cmdRefresh)
	return err
}

func (d *Dm) openArguments(host, session, window string) []string {
	if window == "" {
		window = noWindow
	}
	return []string{cmdApp, cmdOpen, host, session, window, noWindow}
}

func createArguments(host, name, project string) []string {
	arguments := []string{cmdNew, host, name}
	if project != "" {
		arguments = append(arguments, projectSpec+project)
	}
	return arguments
}

// OpenCommand is the full screen version of Open (outside tmux there are no tabs).
func (d *Dm) OpenCommand(host, session, window string) *exec.Cmd {
	if checkOpenArguments(host, session, window) != nil {
		return nil
	}
	return d.command(context.Background(), d.openArguments(host, session, window)...)
}

// CreateCommand is the full screen version of Create.
func (d *Dm) CreateCommand(host, name, project string) *exec.Cmd {
	if checkCreateArguments(host, name, project) != nil {
		return nil
	}
	return d.command(context.Background(), createArguments(host, name, project)...)
}

// ToolCommand runs one of the Tool* actions through "dm _app run"; nil when the arguments
// do not pass validation.
func (d *Dm) ToolCommand(tool string, args ...string) *exec.Cmd {
	if !validTool(tool, args) {
		return nil
	}
	arguments := append([]string{cmdApp, cmdRun, tool}, args...)
	return d.command(context.Background(), arguments...)
}

func validTool(tool string, args []string) bool {
	switch tool {
	case ToolSend, ToolFetch, ToolPort, ToolDevices:
		return len(args) == 0
	case ToolAdd:
		return len(args) == 1 && ValidDeviceName(args[0])
	case ToolWake:
		return len(args) == 1 && ValidHost(args[0])
	default:
		return false
	}
}

// I18n returns the catalog dump of the active language.
func (d *Dm) I18n(ctx context.Context) (string, error) {
	out, err := d.output(ctx, listTimeout, cmdI18n)
	if err != nil {
		return "", fmt.Errorf("catalog: %w", err)
	}
	return out, nil
}
