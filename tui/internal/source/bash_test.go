package source

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// On Termux a script's "#!/usr/bin/env bash" line only works through termux-exec, which Go
// programs bypass: dm must be run through the bash in DM_BASH.
func TestDmRunsThroughDMBashWhenTheShebangCannotWork(t *testing.T) {
	script := filepath.Join(t.TempDir(), "dm")
	body := "#!/nonexistent/bin/bash\nprintf 'V\\t9.9.9\\ttablet\\n'\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	t.Setenv(envDmBash, "")
	if _, err := NewDm(script).output(ctx, time.Second, cmdFeed); err == nil {
		t.Fatal("without DM_BASH the broken shebang should fail, like on Termux")
	}
	t.Setenv(envDmBash, "/bin/bash")
	out, err := NewDm(script).output(ctx, time.Second, cmdFeed)
	if err != nil || out == "" {
		t.Fatalf("through DM_BASH: out=%q err=%v", out, err)
	}
}
