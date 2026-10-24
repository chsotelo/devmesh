package cache

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteThenReadKeepsTheContentPrivate(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DM_CACHE", filepath.Join(dir, "dm"))

	if err := WriteJSON("sidebar-lap.json", map[string]int{"color": 22}); err != nil {
		t.Fatal(err)
	}
	var got map[string]int
	if err := ReadJSON("sidebar-lap.json", &got); err != nil || got["color"] != 22 {
		t.Fatalf("got %v, %v", got, err)
	}
	info, err := os.Stat(filepath.Join(dir, "dm", "sidebar-lap.json"))
	if err != nil || info.Mode().Perm() != fileMode {
		t.Fatalf("mode = %v, %v", info.Mode().Perm(), err)
	}
}

func TestNamesThatCouldLeaveTheDirectoryAreRefused(t *testing.T) {
	t.Setenv("DM_CACHE", t.TempDir())
	for _, name := range []string{"", "../x", "a/b", ".hidden"} {
		if err := Write(name, nil); !errors.Is(err, ErrBadName) {
			t.Fatalf("%q: err = %v", name, err)
		}
	}
}

func TestTheDirectoryFollowsXDGWhenDMCacheIsUnset(t *testing.T) {
	t.Setenv("DM_CACHE", "")
	t.Setenv("XDG_CACHE_HOME", "/tmp/xdg")
	if dir, err := Dir(); err != nil || dir != "/tmp/xdg/devmesh" {
		t.Fatalf("dir = %q, %v", dir, err)
	}
}
