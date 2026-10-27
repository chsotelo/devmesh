package source

import (
	"context"
	"errors"
	"strings"
	"time"
)

// powerTimeout covers the checks the controller makes over the mesh (one ssh per machine).
const powerTimeout = 60 * time.Second

// Words of the dm commands that suspend, power off and wake machines.
const (
	cmdPower = "_power"

	PowerSuspend = "suspend"
	PowerOff     = "off"
	PowerWake    = "wake"
	powerCheck   = "check"

	// Why keys dm answers with (the sentences are in the catalog).
	WhyPowerOK = "ok"
)

var errPowerAnswer = errors.New("dm did not say what is allowed")

// PowerState is what dm allows on a machine: "suspend=1 off=0 wake=0 why=other-lan".
type PowerState struct {
	Suspend bool
	Off     bool
	Wake    bool
	// Why is the key of the reason when nothing is allowed ("ok" otherwise).
	Why string
}

// Any reports whether at least one action is allowed.
func (s PowerState) Any() bool { return s.Suspend || s.Off || s.Wake }

// PowerActor asks dm what may be done to a machine and does it. dm applies the safety rule
// (a machine nobody on its LAN could wake is never suspended or powered off); this side
// only validates what it sends.
type PowerActor interface {
	PowerCheck(ctx context.Context, host string) (PowerState, error)
	Power(ctx context.Context, host, action string) error
}

// PowerCheck asks "dm _power HOST check".
func (d *Dm) PowerCheck(ctx context.Context, host string) (PowerState, error) {
	if !ValidHost(host) {
		return PowerState{}, ErrInvalidArgument
	}
	out, err := d.output(ctx, powerTimeout, cmdPower, host, powerCheck)
	if err != nil {
		return PowerState{}, err
	}
	return parsePower(out)
}

// Power runs "dm _power HOST suspend|off|wake".
func (d *Dm) Power(ctx context.Context, host, action string) error {
	if !ValidHost(host) || !validPowerAction(action) {
		return ErrInvalidArgument
	}
	_, err := d.output(ctx, powerTimeout, cmdPower, host, action)
	return err
}

func validPowerAction(action string) bool {
	return action == PowerSuspend || action == PowerOff || action == PowerWake
}

// parsePower reads the key=value words of the answer; a missing key counts as not allowed.
func parsePower(out string) (PowerState, error) {
	state := PowerState{}
	seen := false
	for _, word := range strings.Fields(out) {
		key, value, found := strings.Cut(word, "=")
		if !found {
			continue
		}
		seen = true
		switch key {
		case "suspend":
			state.Suspend = value == "1"
		case "off":
			state.Off = value == "1"
		case "wake":
			state.Wake = value == "1"
		case "why":
			state.Why = value
		}
	}
	if !seen {
		return PowerState{}, errPowerAnswer
	}
	return state, nil
}
