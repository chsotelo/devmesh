// Package feed holds the data the panel shows and the parser for the "dm _feed" output.
package feed

// AgentState is what a coding agent in a terminal reports through "dm agent".
type AgentState string

// Agent states, as written by the dm hooks.
const (
	AgentNone    AgentState = ""
	AgentWorking AgentState = "working"
	AgentWaiting AgentState = "waiting"
	AgentIdle    AgentState = "idle"
)

// Reach says whether a machine answered the last probe.
type Reach string

// Machine reachability, as classified by dm_collect.
const (
	ReachOnline  Reach = "OK"
	ReachEmpty   Reach = "EMPTY"
	ReachOffline Reach = "OFFLINE"
)

// Terminal is one tmux window on a machine.
type Terminal struct {
	Host       string
	Session    string
	Window     string
	WindowName string
	Active     bool
	Command    string
	Agent      AgentState
	Origin     string
	Created    int64
	Activity   int64
	Clients    string
}

// Key identifies a terminal across refreshes.
func (t Terminal) Key() string { return t.Host + "/" + t.Session + "/" + t.Window }

// Title is the name shown on a card: the session, plus the window when it is not the active one.
func (t Terminal) Title() string {
	if t.Active || t.Window == "" {
		return t.Session
	}
	return t.Session + ":" + t.Window
}

// Machine is a Linux or Mac host that holds terminals.
type Machine struct {
	Name      string
	Reach     Reach
	Color     int
	IP        string
	LAN       string
	HasMAC    bool
	Terminals []Terminal
}

// IsReachable reports whether the machine can be used.
func (m Machine) IsReachable() bool { return m.Reach != ReachOffline }

// Snapshot is one complete reading of the mesh.
type Snapshot struct {
	Device   string
	Version  string
	Machines []Machine
}

// Waiting counts the terminals whose agent waits for the user.
func (s Snapshot) Waiting() int {
	count := 0
	for _, machine := range s.Machines {
		for _, term := range machine.Terminals {
			if term.Agent == AgentWaiting {
				count++
			}
		}
	}
	return count
}

// TerminalCount counts every terminal of every machine.
func (s Snapshot) TerminalCount() int {
	count := 0
	for _, machine := range s.Machines {
		count += len(machine.Terminals)
	}
	return count
}

// FindMachine returns the machine with that name.
func (s Snapshot) FindMachine(name string) (Machine, bool) {
	for _, machine := range s.Machines {
		if machine.Name == name {
			return machine, true
		}
	}
	return Machine{}, false
}

// FindTerminal returns the terminal with that key.
func (s Snapshot) FindTerminal(key string) (Terminal, bool) {
	for _, machine := range s.Machines {
		for _, term := range machine.Terminals {
			if term.Key() == key {
				return term, true
			}
		}
	}
	return Terminal{}, false
}
