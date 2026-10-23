package main

import (
	"errors"
	"flag"
	"io"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/term"

	"github.com/chsotelo/devmesh/tui/internal/sidebar"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

const (
	sidebarCommand = "sidebar"
	hostFlag       = "host"
)

var errBadHost = errors.New("sidebar needs --host <machine>")

// runSidebar runs the list of terminals of one machine (the left pane of the dm layout).
func runSidebar(args []string) error {
	flags := flag.NewFlagSet(sidebarCommand, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	host := flags.String(hostFlag, "", "machine name")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if !source.ValidHost(*host) {
		return errBadHost
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return errNoTerminal
	}
	dm := source.NewDm("")
	model := sidebar.New(sidebar.Options{Host: *host, Source: dm, Catalog: loadCatalog(dm)})
	_, err := tea.NewProgram(model, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}
