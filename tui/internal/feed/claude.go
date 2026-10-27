package feed

import (
	"cmp"
	"slices"
	"strconv"
	"strings"
)

// Time units used by the idle words.
const (
	secsPerMinute = 60
	secsPerHour   = 3600
	secsPerDay    = 86400
	// StaleIdleSecs is how long a session sits idle before the panels offer to stop it.
	StaleIdleSecs = secsPerHour
)

func claudeRank(status ClaudeStatus) int {
	switch status {
	case ClaudeWorking:
		return 0
	case ClaudeWaiting:
		return 1
	default:
		return 2
	}
}

// OrderedSessions is a copy of the sessions: working first, then waiting, then idle ones;
// inside each group the most recently active first.
func OrderedSessions(list []ClaudeSession) []ClaudeSession {
	sorted := slices.Clone(list)
	slices.SortStableFunc(sorted, func(a, b ClaudeSession) int {
		return cmp.Or(
			cmp.Compare(claudeRank(a.Status), claudeRank(b.Status)),
			cmp.Compare(a.IdleSecs, b.IdleSecs),
			cmp.Compare(a.Name, b.Name),
		)
	})
	return sorted
}

// StaleSessions are the idle sessions nobody touched for over an hour.
func StaleSessions(list []ClaudeSession) []ClaudeSession {
	stale := []ClaudeSession{}
	for _, session := range list {
		if session.Status == ClaudeIdle && session.IdleSecs > StaleIdleSecs {
			stale = append(stale, session)
		}
	}
	return stale
}

// IdleWord is "20 min", "5 h" or "3 d".
func IdleWord(secs int64) string {
	switch {
	case secs < secsPerHour:
		return strconv.FormatInt(secs/secsPerMinute, 10) + " min"
	case secs < secsPerDay:
		return strconv.FormatInt(secs/secsPerHour, 10) + " h"
	default:
		return strconv.FormatInt(secs/secsPerDay, 10) + " d"
	}
}

// Why a machine cannot receive a session.
type Why int

// The reasons, in the order the panels check them.
const (
	WhyNone Why = iota
	WhyOff
	WhyNoClaude
	WhyOutdated
)

// MoveTarget is a machine a session could move to.
type MoveTarget struct {
	Machine Machine
	Why     Why
	Load    int
	Best    bool
}

// Eligible reports whether the machine can receive a session.
func (t MoveTarget) Eligible() bool { return t.Why == WhyNone }

// ClaudeLoad is the memory the Claude sessions of a machine use (the closest thing to its
// load that the feed carries).
func ClaudeLoad(machine Machine) int {
	total := 0
	for _, session := range machine.Claude {
		total += session.RSSMB
	}
	return total
}

// MoveTargets are the machines other than from: the ones that can receive first (lowest
// load first, the best one marked), then the ones that cannot, each with its reason.
func MoveTargets(machines []Machine, from string) []MoveTarget {
	targets := []MoveTarget{}
	for _, machine := range machines {
		if machine.Name == from {
			continue
		}
		target := MoveTarget{Machine: machine, Load: ClaudeLoad(machine)}
		switch {
		case !machine.IsReachable():
			target.Why = WhyOff
		case !machine.HasClaude && !machine.ClaudeKnown:
			target.Why = WhyOutdated
		case !machine.HasClaude:
			target.Why = WhyNoClaude
		}
		targets = append(targets, target)
	}
	slices.SortStableFunc(targets, func(a, b MoveTarget) int {
		return cmp.Or(
			cmp.Compare(whyRank(a.Eligible()), whyRank(b.Eligible())),
			cmp.Compare(a.Load, b.Load),
			strings.Compare(a.Machine.Name, b.Machine.Name),
		)
	})
	if len(targets) > 0 && targets[0].Eligible() {
		targets[0].Best = true
	}
	return targets
}

func whyRank(ok bool) int {
	if ok {
		return 0
	}
	return 1
}
