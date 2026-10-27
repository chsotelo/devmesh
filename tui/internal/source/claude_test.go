package source

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

const testSessionID = "0f9c2d4e-1a2b-4c3d-8e9f-aabbccddeeff"

func TestStopClaudeCallsCstopWithHostAndSession(t *testing.T) {
	bin, argLog := stubDm(t)

	if err := NewDm(bin).StopClaude(context.Background(), "lap", testSessionID); err != nil {
		t.Fatalf("StopClaude: %v", err)
	}
	if got := strings.Join(recordedArguments(t, argLog), " "); got != "_cstop lap "+testSessionID {
		t.Fatalf("args = %q", got)
	}
}

func TestResumeClaudeCallsCresumeAndReturnsTheLastLineAsSession(t *testing.T) {
	bin, argLog := stubDm(t)

	session, err := NewDm(bin).ResumeClaude(context.Background(), "lap", testSessionID)

	if err != nil || session != "my-session" {
		t.Fatalf("session=%q err=%v", session, err)
	}
	if got := strings.Join(recordedArguments(t, argLog), " "); got != "_cresume lap "+testSessionID {
		t.Fatalf("args = %q", got)
	}
}

func TestNewClaudeSendsTheNameAsOneArgumentAndTheProjectSpec(t *testing.T) {
	bin, argLog := stubDm(t)

	session, err := NewDm(bin).NewClaude(context.Background(), "lap", "27Oct - my api; rm -rf $HOME", "api")

	if err != nil || session != "my-session" {
		t.Fatalf("session=%q err=%v", session, err)
	}
	want := []string{"_cnew", "lap", "27Oct - my api; rm -rf $HOME", "proj:api"}
	if got := recordedArguments(t, argLog); strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("args = %q, want %q", got, want)
	}
}

func TestMoveClaudeCallsCmoveWithSourceSessionDestination(t *testing.T) {
	bin, argLog := stubDm(t)

	session, err := NewDm(bin).MoveClaude(context.Background(), "mac", testSessionID, "lap")

	if err != nil || session != "my-session" {
		t.Fatalf("session=%q err=%v", session, err)
	}
	if got := strings.Join(recordedArguments(t, argLog), " "); got != "_cmove mac "+testSessionID+" lap" {
		t.Fatalf("args = %q", got)
	}
}

func TestClaudeActionsRefuseBadArgumentsWithoutRunningDm(t *testing.T) {
	bin, argLog := stubDm(t)
	dm, ctx := NewDm(bin), context.Background()

	checks := map[string]error{
		"stop host":    dm.StopClaude(ctx, "Bad Host", testSessionID),
		"stop id":      dm.StopClaude(ctx, "lap", "$(id)"),
		"resume id":    func() error { _, err := dm.ResumeClaude(ctx, "lap", "x y"); return err }(),
		"new project":  func() error { _, err := dm.NewClaude(ctx, "lap", "n", "../etc"); return err }(),
		"new name":     func() error { _, err := dm.NewClaude(ctx, "lap", "bad\x1bname", "api"); return err }(),
		"move same":    func() error { _, err := dm.MoveClaude(ctx, "lap", testSessionID, "lap"); return err }(),
		"move bad dst": func() error { _, err := dm.MoveClaude(ctx, "lap", testSessionID, "A;b"); return err }(),
	}
	for name, err := range checks {
		if !errors.Is(err, ErrInvalidArgument) {
			t.Errorf("%s: err = %v", name, err)
		}
	}
	if _, statErr := os.Stat(argLog); statErr == nil {
		t.Fatal("dm was executed for an invalid argument")
	}
}

func TestClaudeActionReportsDmsOwnMessageOnFailure(t *testing.T) {
	bin, _ := stubDm(t)

	_, err := NewDm(bin).sessionName(context.Background(), "fail")

	if err == nil || err.Error() != "boom" {
		t.Fatalf("err = %v", err)
	}
}

func TestPowerCheckParsesTheAnswerOfDm(t *testing.T) {
	bin, argLog := stubDm(t)
	t.Setenv("STUB_DM_OUT", "suspend=1 off=0 wake=0 why=ok\n")

	state, err := NewDm(bin).PowerCheck(context.Background(), "lap")

	if err != nil || !state.Suspend || state.Off || state.Wake || state.Why != "ok" {
		t.Fatalf("state=%+v err=%v", state, err)
	}
	if got := strings.Join(recordedArguments(t, argLog), " "); got != "_power lap check" {
		t.Fatalf("args = %q", got)
	}
}

func TestPowerCheckWithoutKeysIsAnError(t *testing.T) {
	bin, _ := stubDm(t)
	t.Setenv("STUB_DM_OUT", "garbage\n")

	if _, err := NewDm(bin).PowerCheck(context.Background(), "lap"); err == nil {
		t.Fatal("garbage was accepted")
	}
}

func TestPowerRunsOnlyKnownActionsOnValidHosts(t *testing.T) {
	bin, argLog := stubDm(t)
	dm := NewDm(bin)

	for _, action := range []string{"suspend", "off", "wake"} {
		if err := dm.Power(context.Background(), "lap", action); err != nil {
			t.Fatalf("%s: %v", action, err)
		}
		if got := strings.Join(recordedArguments(t, argLog), " "); got != "_power lap "+action {
			t.Fatalf("args = %q", got)
		}
	}
	if err := dm.Power(context.Background(), "lap", "reboot"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("reboot: %v", err)
	}
	if err := dm.Power(context.Background(), "lap; rm", "off"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatalf("hostile host: %v", err)
	}
}
