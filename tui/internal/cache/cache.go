// Package cache keeps small files between runs, so a new panel draws the last known state
// at once instead of waiting for dm. Everything in it can be lost: it is only a head start.
package cache

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
)

const (
	dirMode  = 0o700
	fileMode = 0o600
	appDir   = "devmesh"
)

var (
	// ErrBadName refuses names that could leave the cache directory.
	ErrBadName = errors.New("invalid cache name")
	errNoHome  = errors.New("no cache directory")
	validName  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$`)
)

// Dir is the cache directory of dm: DM_CACHE, else $XDG_CACHE_HOME/devmesh, else
// ~/.cache/devmesh (the same place the bash dm uses).
func Dir() (string, error) {
	if dir := os.Getenv("DM_CACHE"); dir != "" {
		return dir, nil
	}
	if dir := os.Getenv("XDG_CACHE_HOME"); dir != "" {
		return filepath.Join(dir, appDir), nil
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "", errNoHome
	}
	return filepath.Join(home, ".cache", appDir), nil
}

func pathOf(name string) (string, error) {
	if !validName.MatchString(name) {
		return "", ErrBadName
	}
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name), nil
}

// Read returns the content of a cache file.
func Read(name string) ([]byte, error) {
	path, err := pathOf(name)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}

// Write replaces a cache file atomically (a reader never sees half a file).
func Write(name string, data []byte) error {
	path, err := pathOf(name)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), dirMode); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+name+".*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(fileMode); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// ReadJSON decodes a cache file into value.
func ReadJSON(name string, value any) error {
	data, err := Read(name)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, value)
}

// WriteJSON stores value as a cache file.
func WriteJSON(name string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return Write(name, data)
}
