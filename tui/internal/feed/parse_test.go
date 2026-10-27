package feed

import (
	"strings"
	"testing"
)

const sampleFeed = "V\t0.9.0\ttablet\n" +
	"M\tlaptop\tOK\t33\t10.73.0.2\thome\tmac\n" +
	"T\tlaptop\tapi\t1\tclaude\t1\tclaude\twaiting\ttablet\t1700000000\t1700000100\ttablet\n" +
	"T\tlaptop\tweb\t2\tnode\t0\tnode\t-\tlaptop\t1700000000\t1700000200\t-\n" +
	"M\tdesktop\tOFFLINE\t99\t10.73.0.4\t-\t-\n" +
	"M\tpc2\tEMPTY\t24\t10.73.0.5\t-\tmac\n"

func TestParseBuildsMachinesAndTerminals(t *testing.T) {
	snap := Parse(sampleFeed)

	if snap.Device != "tablet" || snap.Version != "0.9.0" {
		t.Fatalf("header = %q %q", snap.Device, snap.Version)
	}
	if len(snap.Machines) != 3 {
		t.Fatalf("machines = %d, want 3", len(snap.Machines))
	}
	laptop := snap.Machines[0]
	if laptop.Reach != ReachOnline || laptop.Color != 33 || laptop.LAN != "home" || !laptop.HasMAC {
		t.Fatalf("laptop = %+v", laptop)
	}
	if len(laptop.Terminals) != 2 {
		t.Fatalf("laptop terminals = %d, want 2", len(laptop.Terminals))
	}
	api := laptop.Terminals[0]
	if api.Agent != AgentWaiting || !api.Active || api.Clients != "tablet" || api.Activity != 1700000100 {
		t.Fatalf("api = %+v", api)
	}
	if web := laptop.Terminals[1]; web.Clients != "" || web.Agent != AgentNone || web.Active {
		t.Fatalf("web = %+v", web)
	}
	if snap.Machines[1].IsReachable() || snap.Machines[1].HasMAC {
		t.Fatalf("desktop must be offline without a MAC: %+v", snap.Machines[1])
	}
	if snap.Waiting() != 1 || snap.TerminalCount() != 2 {
		t.Fatalf("waiting=%d terminals=%d", snap.Waiting(), snap.TerminalCount())
	}
}

func TestParseStripsEscapesAndControlsFromEveryField(t *testing.T) {
	hostile := "V\t0.9.0\t\x1b[31mtab\x1b[0mlet\n" +
		"M\tlap\x07top\tOK\t33\t10.0.0.2\t-\tmac\n" +
		"T\tlaptop\tapi\t1\t\x1b]0;pwned\x07title\x1b[2J\t1\tcla\x07ude\twaiting\t‮evil\t1700000000\t1700000100\t-\n"

	snap := Parse(hostile)

	if snap.Device != "tablet" {
		t.Fatalf("device = %q, want escapes removed", snap.Device)
	}
	if len(snap.Machines) != 1 || snap.Machines[0].Name != "laptop" {
		t.Fatalf("machines = %+v", snap.Machines)
	}
	terms := snap.Machines[0].Terminals
	if len(terms) != 1 {
		t.Fatalf("terminals = %d, want 1", len(terms))
	}
	if terms[0].WindowName != "title" || terms[0].Command != "claude" || terms[0].Origin != "evil" {
		t.Fatalf("terminal = %+v", terms[0])
	}
	for _, field := range []string{terms[0].WindowName, terms[0].Command, terms[0].Origin, snap.Machines[0].Name, snap.Device} {
		if strings.ContainsAny(field, "\x1b\x07‮") {
			t.Fatalf("field %q still holds control characters", field)
		}
	}
}

func TestParseSkipsMalformedAndUnknownRecords(t *testing.T) {
	raw := "garbage line\n" +
		"M\tonly\tthree\n" +
		"T\tghost\tapi\t1\tn\t1\tc\t-\t-\t1\t1\t-\n" +
		"X\twhatever\n" +
		"M\tok\tOK\t1\t1.1.1.1\t-\t-\n" +
		"T\tok\t\t1\tn\t1\tc\t-\t-\t1\t1\t-\n" +
		"T\tok\ttoo\tfew\n"

	snap := Parse(raw)

	if len(snap.Machines) != 1 || snap.Machines[0].Name != "ok" {
		t.Fatalf("machines = %+v", snap.Machines)
	}
	if got := len(snap.Machines[0].Terminals); got != 0 {
		t.Fatalf("terminals = %d, want 0 (unknown host, empty session, short line)", got)
	}
}

func TestParseTurnsUnknownValuesIntoSafeDefaults(t *testing.T) {
	raw := "M\tlap\tWEIRD\tnotanumber\t-\t-\t-\n" +
		"T\tlap\tapi\t1\tn\t1\tc\tbogus\t-\t-5\tabc\t-\n"

	snap := Parse(raw)

	lap := snap.Machines[0]
	if lap.Reach != ReachOffline || lap.Color != 0 {
		t.Fatalf("machine = %+v", lap)
	}
	term := lap.Terminals[0]
	if term.Agent != AgentNone || term.Created != 0 || term.Activity != 0 {
		t.Fatalf("terminal = %+v", term)
	}
}

func TestCleanLinesDropsEscapesAndKeepsText(t *testing.T) {
	lines := CleanLines("\x1b[31mred\x1b[0m text\r\nsecond\tcol\n\x1b]52;c;ZXZpbA==\x07third")

	want := []string{"red text", "second    col", "third"}
	if len(lines) != len(want) {
		t.Fatalf("lines = %q", lines)
	}
	for i := range want {
		if lines[i] != want[i] {
			t.Fatalf("line %d = %q, want %q", i, lines[i], want[i])
		}
	}
}

func TestTrimBlankAndLastLines(t *testing.T) {
	trimmed := TrimBlank([]string{"", "  ", "a", "", "b", "", ""})
	if len(trimmed) != 3 || trimmed[0] != "a" || trimmed[2] != "b" {
		t.Fatalf("trimmed = %q", trimmed)
	}
	last := LastLines([]string{"a", "b", "c", "d"}, 2)
	if len(last) != 2 || last[0] != "c" {
		t.Fatalf("last = %q", last)
	}
	if got := LastLines([]string{"a"}, 0); len(got) != 0 {
		t.Fatalf("LastLines(…, 0) = %q", got)
	}
}

func TestTerminalTitleShowsWindowOnlyWhenNotActive(t *testing.T) {
	active := Terminal{Session: "api", Window: "1", Active: true}
	other := Terminal{Host: "lap", Session: "api", Window: "2"}

	if active.Title() != "api" || other.Title() != "api:2" || other.Key() != "lap/api/2" {
		t.Fatalf("titles: %q %q %q", active.Title(), other.Title(), other.Key())
	}
}

const (
	sidOne = "0f9c2d4e-1a2b-4c3d-8e9f-aabbccddeeff"
	sidTwo = "11111111-2222-3333-4444-555555555555"
)

func TestParseReadsClaudeSessionsHistoryAndAvailability(t *testing.T) {
	raw := "M\tlaptop\tOK\t33\t10.73.0.2\t-\tmac\n" +
		"K\tlaptop\t1\n" +
		"C\tlaptop\t" + sidOne + "\tbusy\t4\tmain:@2.%5\t262\t/home/u/PROJECTS/x\t27Oct - tools\n" +
		"C\tlaptop\t" + sidTwo + "\tidle\t4621\t-\t19\t/home/u/PROJECTS/y\t23Oct - ebbine bugs\n" +
		"H\tlaptop\t" + sidOne + "\t3600\t/home/u/PROJECTS/x\t18Oct - form guide\n" +
		"M\tpc2\tOK\t24\t10.73.0.5\t-\t-\n" +
		"K\tpc2\t0\n"

	snap := Parse(raw)

	laptop := snap.Machines[0]
	if !laptop.HasClaude || len(laptop.Claude) != 2 || len(laptop.History) != 1 {
		t.Fatalf("laptop = %+v", laptop)
	}
	live := laptop.Claude[0]
	if live.Status != ClaudeWorking || live.IdleSecs != 4 || live.RSSMB != 262 || live.Name != "27Oct - tools" ||
		live.Tmux != "main:@2.%5" || live.TmuxSession() != "main" || !live.Openable() || live.Machine != "laptop" {
		t.Fatalf("live = %+v", live)
	}
	outside := laptop.Claude[1]
	if outside.Status != ClaudeIdle || outside.Openable() || outside.Tmux != "" {
		t.Fatalf("outside = %+v", outside)
	}
	if past := laptop.History[0]; past.AgeSecs != 3600 || past.Name != "18Oct - form guide" || past.Cwd != "/home/u/PROJECTS/x" {
		t.Fatalf("history = %+v", past)
	}
	if snap.Machines[1].HasClaude {
		t.Fatal("K 0 means the machine has no Claude")
	}
}

func TestParseMapsClaudeStatuses(t *testing.T) {
	for raw, want := range map[string]ClaudeStatus{
		"busy": ClaudeWorking, "shell": ClaudeWorking, "working": ClaudeWorking,
		"waiting": ClaudeWaiting, "idle": ClaudeIdle, "weird": ClaudeIdle,
	} {
		if got := parseClaudeStatus(raw); got != want {
			t.Errorf("%s = %s, want %s", raw, got, want)
		}
	}
}

func TestParseDropsMalformedOrHostileClaudeRecords(t *testing.T) {
	raw := "M\tlaptop\tOK\t33\t10.73.0.2\t-\tmac\n" +
		"C\tlaptop\tnot a uuid\tbusy\t4\t-\t1\t/x\tname\n" +
		"C\tlaptop\t" + sidOne + "\tbusy\t4\t-\t1\t/x\n" +
		"C\tlaptop\t" + sidOne + "\tbusy\t4\n" +
		"C\tghost\t" + sidOne + "\tbusy\t4\t-\t1\t/x\tname\n" +
		"H\tlaptop\t$(rm -rf)\t5\t/x\tname\n" +
		"H\tlaptop\t" + sidTwo + "\t5\t/x\n" +
		"K\tghost\t1\n" +
		"C\tlaptop\t" + sidTwo + "\tbusy\t4\t-\t1\t/x\t\x1b[31mred\x1b[0m\x07 name\n"

	laptop := Parse(raw).Machines[0]

	if len(laptop.History) != 0 {
		t.Fatalf("history = %+v", laptop.History)
	}
	if len(laptop.Claude) != 1 || laptop.Claude[0].Name != "red name" {
		t.Fatalf("claude = %+v", laptop.Claude)
	}
}

func TestParseKeepsTabsInsideAClaudeName(t *testing.T) {
	raw := "M\tlaptop\tOK\t33\t10.73.0.2\t-\tmac\n" +
		"C\tlaptop\t" + sidOne + "\tidle\t4\t-\t1\t/x\ta\tb\n"

	if got := Parse(raw).Machines[0].Claude[0].Name; got != "a b" {
		t.Fatalf("name = %q", got)
	}
}

func TestAMachineThatDoesNotReportClaudeIsOutdatedNotWithoutClaude(t *testing.T) {
	snap := Parse("V\t0.11.0\tmac\n" +
		"M\tmac\tOK\t22\t10.73.0.2\t-\t-\n" +
		"M\tlaptop\tOK\t24\t10.73.0.4\thome\tmac\n" +
		"M\tpc2\tOK\t30\t10.73.0.5\t-\t-\n" +
		"K\tmac\t1\n" +
		"K\tpc2\t0\n")

	why := map[string]Why{}
	for _, target := range MoveTargets(snap.Machines, "mac") {
		why[target.Machine.Name] = target.Why
	}
	if why["laptop"] != WhyOutdated || why["pc2"] != WhyNoClaude {
		t.Fatalf("why = %v", why)
	}
}

func TestCleanDropsC1AndBidiControls(t *testing.T) {
	raw := "a\u0085b\u009bc\u202Ed\u202Ae\u2066f\u2069g\u200Eh\u200Fi"
	if got := Clean(raw); got != "abcdefghi" {
		t.Fatalf("Clean = %q", got)
	}
}
