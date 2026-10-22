package ui

import (
	"context"
	"errors"
	"os/exec"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/chsotelo/devmesh/tui/internal/feed"
	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

// fixedNow is the clock of every test: agent "ago" times are relative to it.
var fixedNow = time.Unix(1_700_000_000, 0)

func init() {
	lipgloss.SetColorProfile(termenv.Ascii)
}

// fakeSource answers from memory and records what was asked.
type fakeSource struct {
	mu        sync.Mutex
	snapshot  feed.Snapshot
	screens   map[string][]string
	projects  []string
	devices   string
	feedErr   error
	opened    []string
	created   []string
	validated []string
	refreshes int
}

func (f *fakeSource) Feed(context.Context) (feed.Snapshot, error) {
	return f.snapshot, f.feedErr
}

func (f *fakeSource) Shot(_ context.Context, host, session, window string) ([]string, error) {
	return f.screens[host+"/"+session+"/"+window], nil
}

func (f *fakeSource) Projects(context.Context, string) ([]string, error) { return f.projects, nil }

func (f *fakeSource) Devices(context.Context) (string, error) { return f.devices, nil }

func (f *fakeSource) Open(_ context.Context, host, session, window string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.opened = append(f.opened, host+"/"+session+"/"+window)
	return nil
}

func (f *fakeSource) Create(_ context.Context, host, name, project string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.created = append(f.created, host+"|"+name+"|"+project)
	return nil
}

func (f *fakeSource) Validate(_ context.Context, host, name, project string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.validated = append(f.validated, host+"|"+name+"|"+project)
	return nil
}

func (f *fakeSource) Refresh(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.refreshes++
	return nil
}

func (f *fakeSource) OpenCommand(host, session, window string) *exec.Cmd {
	return exec.Command("true", host, session, window)
}

func (f *fakeSource) CreateCommand(host, name, project string) *exec.Cmd {
	return exec.Command("true", host, name, project)
}

func (f *fakeSource) ToolCommand(tool string, args ...string) *exec.Cmd {
	return exec.Command("true", append([]string{tool}, args...)...)
}

var errFeedDown = errors.New("hub unreachable")

// sampleSnapshot is the mesh of every layout test: one busy machine, one off, one empty.
func sampleSnapshot() feed.Snapshot {
	now := fixedNow.Unix()
	return feed.Snapshot{
		Device:  "tablet",
		Version: "0.9.0",
		Machines: []feed.Machine{
			{Name: "laptop", Reach: feed.ReachOnline, Color: 33, IP: "10.73.0.2", Terminals: []feed.Terminal{
				{Host: "laptop", Session: "api", Window: "1", Active: true, Command: "claude", Agent: feed.AgentWaiting, Origin: "tablet", Activity: now - 40, Clients: "tablet"},
				{Host: "laptop", Session: "web", Window: "1", Active: true, Command: "node", Origin: "laptop", Activity: now - 300},
				{Host: "laptop", Session: "docs", Window: "1", Active: true, Command: "claude", Agent: feed.AgentWorking, Origin: "laptop", Activity: now - 5},
			}},
			{Name: "desktop", Reach: feed.ReachOffline, Color: 99, IP: "10.73.0.4"},
			{Name: "pc2", Reach: feed.ReachEmpty, Color: 24, IP: "10.73.0.5"},
		},
	}
}

func sampleScreens() map[string][]string {
	return map[string][]string{
		"laptop/api/1":  {"$ claude", "", "I updated the auth middleware and added tests.", "", "Edit src/auth.ts?", "> 1. Yes", "  2. Yes, and don't ask again", "  3. No"},
		"laptop/web/1":  {"$ npm run dev", "", "VITE v6 ready in 312 ms", "Local: http://localhost:5173/"},
		"laptop/docs/1": {"$ claude", "", "Writing docs/guide.md..."},
	}
}

// newTestModel builds a model of the given size that already holds the sample mesh.
func newTestModel(t *testing.T, width, height int, inTmux bool) (*Model, *fakeSource) {
	t.Helper()
	fake := &fakeSource{snapshot: sampleSnapshot(), screens: sampleScreens(), projects: []string{"api", "docs", "mobile"}, devices: "laptop  machine\ntablet  phone"}
	model := New(Options{Source: fake, Catalog: i18n.Fallback(), InTmux: inTmux, Version: "dev", Now: func() time.Time { return fixedNow }})
	model.Update(tea.WindowSizeMsg{Width: width, Height: height})
	model.Update(feedMsg{seq: model.feedSeq, snap: fake.snapshot})
	model.inflight = map[string]int{}
	for key, lines := range fake.screens {
		model.shots[key] = shot{lines: lines, at: fixedNow}
	}
	return model, fake
}

var _ source.Source = (*fakeSource)(nil)
