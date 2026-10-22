// Command dm-tui is the touch-friendly control panel of devmesh. It only draws: every remote
// or sensitive operation is done by the bash "dm" command it is started from.
package main

import (
	"context"
	"errors"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/term"

	"github.com/chsotelo/devmesh/tui/internal/i18n"
	"github.com/chsotelo/devmesh/tui/internal/source"
	"github.com/chsotelo/devmesh/tui/internal/ui"
)

// version is set at build time: -ldflags "-X main.version=1.2.3".
var version = "dev"

const (
	catalogTimeout = 4 * time.Second
	exitUsage      = 2
	exitFailure    = 1
	versionFlag    = "--version"
	tmuxVariable   = "TMUX"
)

var errNoTerminal = errors.New("dm-tui needs an interactive terminal (run it through: dm)")

func main() {
	if len(os.Args) > 1 && os.Args[1] == versionFlag {
		_, _ = os.Stdout.WriteString("dm-tui " + version + "\n")
		return
	}
	if err := runPanel(); err != nil {
		_, _ = os.Stderr.WriteString("dm-tui: " + err.Error() + "\n")
		if errors.Is(err, errNoTerminal) {
			os.Exit(exitUsage)
		}
		os.Exit(exitFailure)
	}
}

// runPanel loads the catalog and runs the full screen panel until the user quits.
func runPanel() error {
	if !term.IsTerminal(int(os.Stdin.Fd())) || !term.IsTerminal(int(os.Stdout.Fd())) {
		return errNoTerminal
	}
	dm := source.NewDm("")
	model := ui.New(ui.Options{
		Source:  source.NewThrottled(dm),
		Catalog: loadCatalog(dm),
		InTmux:  os.Getenv(tmuxVariable) != "",
		Version: version,
	})
	_, err := tea.NewProgram(model, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	return err
}

// loadCatalog reads the active language from dm; the embedded English one fills any gap.
func loadCatalog(dm *source.Dm) i18n.Catalog {
	ctx, cancel := context.WithTimeout(context.Background(), catalogTimeout)
	defer cancel()
	dump, err := dm.I18n(ctx)
	if err != nil {
		return i18n.Fallback()
	}
	return i18n.Parse(dump).WithFallback()
}
