package source

import (
	"context"
	"os/exec"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/chsotelo/devmesh/tui/internal/feed"
)

// gatedSource blocks every Shot until release is closed and records the peak concurrency.
type gatedSource struct {
	Source
	running atomic.Int32
	peak    atomic.Int32
	entered chan struct{}
	release chan struct{}
}

func (g *gatedSource) Shot(context.Context, string, string, string) ([]string, error) {
	now := g.running.Add(1)
	for {
		seen := g.peak.Load()
		if now <= seen || g.peak.CompareAndSwap(seen, now) {
			break
		}
	}
	g.entered <- struct{}{}
	<-g.release
	g.running.Add(-1)
	return nil, nil
}

func (g *gatedSource) Feed(context.Context) (feed.Snapshot, error) { return feed.Snapshot{}, nil }

func (g *gatedSource) OpenCommand(string, string, string) *exec.Cmd { return nil }

func TestThrottledRunsAtMostFourCapturesAtOnce(t *testing.T) {
	const callers = 10
	gated := &gatedSource{entered: make(chan struct{}, callers), release: make(chan struct{})}
	throttled := NewThrottled(gated)
	var done sync.WaitGroup
	for range callers {
		done.Add(1)
		go func() {
			defer done.Done()
			if _, err := throttled.Shot(context.Background(), "lap", "api", "1"); err != nil {
				t.Errorf("Shot: %v", err)
			}
		}()
	}

	for range MaxConcurrentShots {
		<-gated.entered
	}
	close(gated.release)
	done.Wait()

	if peak := gated.peak.Load(); peak != MaxConcurrentShots {
		t.Fatalf("peak concurrency = %d, want %d", peak, MaxConcurrentShots)
	}
}

func TestThrottledGivesUpWhenTheContextEndsWhileWaiting(t *testing.T) {
	gated := &gatedSource{entered: make(chan struct{}, MaxConcurrentShots), release: make(chan struct{})}
	throttled := NewThrottled(gated)
	var holders sync.WaitGroup
	for range MaxConcurrentShots {
		holders.Add(1)
		go func() {
			defer holders.Done()
			_, _ = throttled.Shot(context.Background(), "lap", "api", "1")
		}()
	}
	for range MaxConcurrentShots {
		<-gated.entered
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := throttled.Shot(ctx, "lap", "api", "1")

	close(gated.release)
	holders.Wait()
	if err == nil {
		t.Fatal("a canceled caller must not wait for a free slot")
	}
}
