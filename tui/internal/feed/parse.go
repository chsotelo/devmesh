package feed

import (
	"bufio"
	"strconv"
	"strings"
)

// Record tags of the "dm _feed" output.
const (
	tagVersion  = "V"
	tagMachine  = "M"
	tagTerminal = "T"
	noValue     = "-"
	fieldSep    = "\t"
	activeFlag  = "1"
)

const (
	versionFields  = 3
	machineFields  = 7
	terminalFields = 12
	maxLineBytes   = 1024 * 1024
	initialBuffer  = 64 * 1024
)

// Parse reads the TSV that "dm _feed" prints. Unknown or malformed lines are skipped, and
// every text field is cleaned: the machines are not trusted to send printable text.
func Parse(raw string) Snapshot {
	var snap Snapshot
	index := map[string]int{}
	scanner := bufio.NewScanner(strings.NewReader(raw))
	scanner.Buffer(make([]byte, 0, initialBuffer), maxLineBytes)
	for scanner.Scan() {
		fields := strings.Split(strings.TrimRight(scanner.Text(), crRune), fieldSep)
		switch fields[0] {
		case tagVersion:
			applyVersion(&snap, fields)
		case tagMachine:
			addMachine(&snap, index, fields)
		case tagTerminal:
			addTerminal(&snap, index, fields)
		}
	}
	return snap
}

func applyVersion(snap *Snapshot, fields []string) {
	if len(fields) < versionFields {
		return
	}
	snap.Version = Clean(fields[1])
	snap.Device = Clean(fields[2])
}

func addMachine(snap *Snapshot, index map[string]int, fields []string) {
	if len(fields) < machineFields {
		return
	}
	name := Clean(fields[1])
	if name == "" {
		return
	}
	color, _ := strconv.Atoi(Clean(fields[3]))
	machine := Machine{
		Name:   name,
		Reach:  parseReach(Clean(fields[2])),
		Color:  color,
		IP:     Clean(fields[4]),
		LAN:    orEmpty(Clean(fields[5])),
		HasMAC: Clean(fields[6]) != noValue,
	}
	index[name] = len(snap.Machines)
	snap.Machines = append(snap.Machines, machine)
}

func addTerminal(snap *Snapshot, index map[string]int, fields []string) {
	if len(fields) < terminalFields {
		return
	}
	position, known := index[Clean(fields[1])]
	if !known {
		return
	}
	term := Terminal{
		Host:       snap.Machines[position].Name,
		Session:    Clean(fields[2]),
		Window:     Clean(fields[3]),
		WindowName: Clean(fields[4]),
		Active:     Clean(fields[5]) == activeFlag,
		Command:    Clean(fields[6]),
		Agent:      parseAgent(Clean(fields[7])),
		Origin:     orEmpty(Clean(fields[8])),
		Created:    parseSeconds(fields[9]),
		Activity:   parseSeconds(fields[10]),
		Clients:    orEmpty(Clean(fields[11])),
	}
	if term.Session == "" {
		return
	}
	snap.Machines[position].Terminals = append(snap.Machines[position].Terminals, term)
}

func parseReach(value string) Reach {
	switch Reach(value) {
	case ReachOnline, ReachEmpty:
		return Reach(value)
	default:
		return ReachOffline
	}
}

func parseAgent(value string) AgentState {
	switch AgentState(value) {
	case AgentWorking, AgentWaiting, AgentIdle:
		return AgentState(value)
	default:
		return AgentNone
	}
}

func parseSeconds(value string) int64 {
	seconds, err := strconv.ParseInt(strings.TrimSpace(Clean(value)), 10, 64)
	if err != nil || seconds < 0 {
		return 0
	}
	return seconds
}

func orEmpty(value string) string {
	if value == noValue {
		return ""
	}
	return value
}
