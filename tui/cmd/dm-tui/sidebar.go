package main

import (
	"errors"
	"flag"
	"io"
	"os"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/term"

	"github.com/chsotelo/devmesh/tui/internal/cache"
	"github.com/chsotelo/devmesh/tui/internal/sidebar"
	"github.com/chsotelo/devmesh/tui/internal/source"
)

const (
	sidebarCommand = "sidebar"
	hostFlag       = "host"
	// sidebarCachePrefix + HOST + sidebarCacheSuffix keeps the last list of a machine.
	sidebarCachePrefix = "sidebar-"
	sidebarCacheSuffix = ".json"
)

// fileMemory keeps the last list of each machine in dm's cache directory.
type fileMemory struct{}

func (fileMemory) Load(host string) (sidebar.Saved, bool) {
	var saved sidebar.Saved
	err := cache.ReadJSON(sidebarCachePrefix+host+sidebarCacheSuffix, &saved)
	return saved, err == nil
}

func (fileMemory) Save(host string, saved sidebar.Saved) {
	_ = cache.WriteJSON(sidebarCachePrefix+host+sidebarCacheSuffix, saved)
}

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
	model := sidebar.New(sidebar.Options{Host: *host, Source: dm, Catalog: loadCatalog(dm), Memory: fileMemory{}})
	_, err := tea.NewProgram(model, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}
