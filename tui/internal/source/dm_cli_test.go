package source

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stubDm writes a fake dm that records its arguments (one per line) and answers canned output.
func stubDm(t *testing.T) (bin, argLog string) {
	t.Helper()
	dir := t.TempDir()
	argLog = filepath.Join(dir, "args.log")
	script := `#!/bin/sh
printf '%s\n' "$@" > "$STUB_LOG"
case "$1" in
  _ws) case "$2" in shown) printf 'api\n' ;; esac ;;
  _feed) printf 'V\t0.9.0\ttablet\nM\tlap\tOK\t33\t10.0.0.2\t-\tmac\nT\tlap\tapi\t1\tn\t1\tclaude\twaiting\ttablet\t1\t2\t-\n' ;;
  _shot) printf '\n\033[31mred\033[0m line\nsecond\n\n\n' ;;
  _proj) printf 'api\nmy app\nx);rm -rf /\n$(id)\ndocs\n' ;;
  devices) printf 'lap machine\ntablet phone\n' ;;
  _cstop) ;;
  _power) printf '%s' "$STUB_DM_OUT" ;;
  _cresume|_cnew|_cmove) printf 'progress\nmy-session\n' ;;
  fail) printf 'error: boom\n' >&2; exit 3 ;;
esac
`
	bin = filepath.Join(dir, "dm")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	t.Setenv("STUB_LOG", argLog)
	return bin, argLog
}

func recordedArguments(t *testing.T, argLog string) []string {
	t.Helper()
	raw, err := os.ReadFile(argLog)
	if err != nil {
		t.Fatalf("the stub was not called: %v", err)
	}
	return strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
}

func TestFeedParsesTheOutputOfDmFeed(t *testing.T) {
	bin, argLog := stubDm(t)

	snap, err := NewDm(bin).Feed(context.Background())

	if err != nil {
		t.Fatalf("Feed: %v", err)
	}
	if len(snap.Machines) != 1 || len(snap.Machines[0].Terminals) != 1 || snap.Device != "tablet" {
		t.Fatalf("snapshot = %+v", snap)
	}
	if args := recordedArguments(t, argLog); len(args) != 1 || args[0] != "_feed" {
		t.Fatalf("args = %q", args)
	}
}

func TestShotCleansTheScreenAndPassesPlainArguments(t *testing.T) {
	bin, argLog := stubDm(t)

	lines, err := NewDm(bin).Shot(context.Background(), "lap", "api", "1")

	if err != nil {
		t.Fatalf("Shot: %v", err)
	}
	if len(lines) != 2 || lines[0] != "red line" || lines[1] != "second" {
		t.Fatalf("lines = %q", lines)
	}
	if args := strings.Join(recordedArguments(t, argLog), " "); args != "_shot lap api 1" {
		t.Fatalf("args = %q", args)
	}
}

func TestProjectsKeepsOnlyPlainFolderNames(t *testing.T) {
	bin, _ := stubDm(t)

	names, err := NewDm(bin).Projects(context.Background(), "lap")

	if err != nil {
		t.Fatalf("Projects: %v", err)
	}
	if strings.Join(names, ",") != "api,docs" {
		t.Fatalf("names = %q, hostile folder names must be dropped", names)
	}
}

func TestInvalidArgumentsNeverReachDm(t *testing.T) {
	bin, argLog := stubDm(t)
	dm := NewDm(bin)
	ctx := context.Background()

	if _, err := dm.Shot(ctx, "lap;rm", "api", "1"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("host: %v", err)
	}
	if _, err := dm.Shot(ctx, "lap", "a b", "1"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("session: %v", err)
	}
	if err := dm.Open(ctx, "lap", "api", "x"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("window: %v", err)
	}
	if err := dm.Create(ctx, "lap", "bad\x1bname", ""); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("name: %v", err)
	}
	if err := dm.Create(ctx, "lap", "ok", "../etc"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("project: %v", err)
	}
	if _, statErr := os.Stat(argLog); statErr == nil {
		t.Fatal("dm was executed for an invalid argument")
	}
}

func TestCreateSendsTheNameAsOneArgumentWithoutAShell(t *testing.T) {
	bin, argLog := stubDm(t)

	err := NewDm(bin).Create(context.Background(), "lap", "my api; rm -rf $HOME", "api")

	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	want := []string{"_new", "lap", "my api; rm -rf $HOME", "proj:api"}
	got := recordedArguments(t, argLog)
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("args = %q, want %q", got, want)
	}
}

func TestValidateAddsTheCheckFlag(t *testing.T) {
	bin, argLog := stubDm(t)

	if err := NewDm(bin).Validate(context.Background(), "lap", "web", ""); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if got := strings.Join(recordedArguments(t, argLog), " "); got != "_new --check lap web -" && got != "_new --check lap web" {
		t.Fatalf("args = %q", got)
	}
}

func TestOpenUsesDmAppOpenWithDashForNoWindow(t *testing.T) {
	bin, argLog := stubDm(t)

	if err := NewDm(bin).Open(context.Background(), "lap", "main", ""); err != nil {
		t.Fatalf("Open: %v", err)
	}
	if got := strings.Join(recordedArguments(t, argLog), " "); got != "_app open lap main - -" {
		t.Fatalf("args = %q", got)
	}
}

func TestCommandFailureReportsDmsOwnMessage(t *testing.T) {
	bin, _ := stubDm(t)

	_, err := NewDm(bin).output(context.Background(), actionTimeout, "fail")

	if err == nil || err.Error() != "boom" {
		t.Fatalf("err = %v, want the stderr message without the prefix", err)
	}
}

func TestDevicesReturnsTheListAsText(t *testing.T) {
	bin, _ := stubDm(t)

	text, err := NewDm(bin).Devices(context.Background())

	if err != nil || text != "lap machine\ntablet phone" {
		t.Fatalf("Devices = %q, %v", text, err)
	}
}

func TestToolCommandBuildsArgvAndRejectsBadArguments(t *testing.T) {
	dm := NewDm("dm")

	send := dm.ToolCommand(ToolSend)
	if send == nil || strings.Join(send.Args, " ") != "dm _app run send" {
		t.Fatalf("send = %v", send)
	}
	add := dm.ToolCommand(ToolAdd, "tablet-2")
	if add == nil || add.Args[len(add.Args)-1] != "tablet-2" {
		t.Fatalf("add = %v", add)
	}
	for _, bad := range [][]string{{ToolAdd, "Bad Name"}, {ToolAdd, "hub1"}, {ToolWake, "lap;x"}, {"rm", "-rf"}, {ToolSend, "extra"}} {
		if command := dm.ToolCommand(bad[0], bad[1:]...); command != nil {
			t.Fatalf("%v must be refused, got %v", bad, command.Args)
		}
	}
}

func TestNewDmFallsBackToTheEnvironmentThenToPath(t *testing.T) {
	t.Setenv(envDmSelf, "/opt/dm")
	if got := NewDm("").bin; got != "/opt/dm" {
		t.Fatalf("bin = %q", got)
	}
	t.Setenv(envDmSelf, "")
	if got := NewDm("").bin; got != "dm" {
		t.Fatalf("bin = %q", got)
	}
}

func TestWorkspaceCommandsPassValidatedPlainArguments(t *testing.T) {
	bin, argLog := stubDm(t)
	dm := NewDm(bin)

	if err := dm.Show(context.Background(), PaneTarget{Host: "lap", Session: "api", Window: "2", Focus: true}); err != nil {
		t.Fatalf("Show: %v", err)
	}
	if args := strings.Join(recordedArguments(t, argLog), " "); args != "_ws show lap api 2 focus" {
		t.Fatalf("args = %q", args)
	}
	if err := dm.Hold(context.Background(), "lap", HoldOffline); err != nil {
		t.Fatalf("Hold: %v", err)
	}
	if args := strings.Join(recordedArguments(t, argLog), " "); args != "_ws hold lap offline" {
		t.Fatalf("args = %q", args)
	}
	if err := dm.Hold(context.Background(), "lap", HoldChoose); err != nil {
		t.Fatalf("Hold choose: %v", err)
	}
	if args := strings.Join(recordedArguments(t, argLog), " "); args != "_ws hold lap choose" {
		t.Fatalf("args = %q", args)
	}
	if err := dm.SetHeader(context.Background(), "lap", Header{Title: "27Oct - tools", Stop: "Stop", Move: "Move to desk"}); err != nil {
		t.Fatalf("Header: %v", err)
	}
	if args := recordedArguments(t, argLog); strings.Join(args, "|") != "_ws|header|lap|27Oct - tools|Stop|Move to desk" {
		t.Fatalf("args = %q", args)
	}
	if err := dm.SetHeader(context.Background(), "lap", Header{}); err != nil {
		t.Fatalf("Header clear: %v", err)
	}
	if args := strings.Join(recordedArguments(t, argLog), " "); args != "_ws header lap" {
		t.Fatalf("args = %q", args)
	}
	if err := dm.SetHeader(context.Background(), "L A", Header{Title: "x", Stop: "y", Move: "z"}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("Header host: %v", err)
	}
	session, err := dm.Shown(context.Background(), "lap")
	if err != nil || session != "api" {
		t.Fatalf("Shown = %q, %v", session, err)
	}
	snap, err := dm.FeedHost(context.Background(), "lap")
	if err != nil || len(snap.Machines) != 1 {
		t.Fatalf("FeedHost = %+v, %v", snap, err)
	}
	if args := strings.Join(recordedArguments(t, argLog), " "); args != "_feed lap" {
		t.Fatalf("args = %q", args)
	}
}

func TestWorkspaceCommandsRefuseHostileArgumentsBeforeRunning(t *testing.T) {
	bin, _ := stubDm(t)
	dm := NewDm(bin)
	ctx := context.Background()

	if err := dm.Show(ctx, PaneTarget{Host: "lap", Session: "a;b", Window: "1"}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("Show session: %v", err)
	}
	if err := dm.Show(ctx, PaneTarget{Host: "L A", Session: "api"}); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("Show host: %v", err)
	}
	if err := dm.Hold(ctx, "lap", "x; id"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("Hold kind: %v", err)
	}
	if _, err := dm.Shown(ctx, "$(id)"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("Shown host: %v", err)
	}
	if _, err := dm.FeedHost(ctx, "a b"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("FeedHost host: %v", err)
	}
}
