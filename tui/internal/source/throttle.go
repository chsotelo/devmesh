package source

import "context"

// MaxConcurrentShots bounds how many captures run at once, so a long list of terminals
// never opens a burst of ssh connections.
const MaxConcurrentShots = 4

// Throttled limits the concurrent calls of Shot.
type Throttled struct {
	Source
	slots chan struct{}
}

// NewThrottled wraps a Source so at most MaxConcurrentShots captures run at once.
func NewThrottled(inner Source) *Throttled {
	return &Throttled{Source: inner, slots: make(chan struct{}, MaxConcurrentShots)}
}

// Shot waits for a free slot (or the context) and then reads the screen.
func (t *Throttled) Shot(ctx context.Context, host, session, window string) ([]string, error) {
	select {
	case t.slots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-t.slots }()
	return t.Source.Shot(ctx, host, session, window)
}
