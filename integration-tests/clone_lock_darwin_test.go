package integration_test

import (
	"bytes"
	"context"
	"encoding/json"
	"integration/tart"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Exercise the real CLI with synthetic VM files and the same POSIX record lock
// used by tart run. This needs macOS, but does not boot a VM or download images.
func TestClonePreservesRunningDestination(t *testing.T) {
	home := t.TempDir()
	t.Setenv("TART_HOME", home)
	t.Setenv("TART_NO_AUTO_PRUNE", "1")
	createSyntheticVM(t, home, "source", "92:81:b5:ab:39:37")
	destination := createSyntheticVM(t, home, "destination", "92:81:b5:ab:39:38")

	if _, stderr, err := tart.Tart(t, "clone", "source", "new-destination"); err != nil {
		t.Fatalf("clone to new destination: %v: %s", err, stderr)
	}
	config := filepath.Join(destination, "config.json")
	original, err := os.ReadFile(config)
	if err != nil {
		t.Fatal(err)
	}
	held, err := os.OpenFile(config, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { held.Close() })
	originalInfo, err := held.Stat()
	if err != nil {
		t.Fatal(err)
	}
	lock := syscall.Flock_t{Type: syscall.F_WRLCK, Whence: 0}
	if err := syscall.FcntlFlock(held.Fd(), syscall.F_SETLK, &lock); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		_, stderr, err := tart.Tart(t, "clone", "source", "destination")
		if err == nil || !strings.Contains(strings.ToLower(stderr), "running") {
			t.Fatalf("clone must reject the running destination: %v: %s", err, stderr)
		}
		currentInfo, err := os.Stat(config)
		if err != nil || !os.SameFile(originalInfo, currentInfo) {
			t.Fatalf("clone replaced the locked config: %v", err)
		}
		// Opening and closing config again would release our process's record lock.
		current := make([]byte, len(original))
		if _, err := held.ReadAt(current, 0); err != nil || !bytes.Equal(original, current) {
			t.Fatalf("clone changed the locked config: %v", err)
		}
	}
	lock.Type = syscall.F_UNLCK
	if err := syscall.FcntlFlock(held.Fd(), syscall.F_SETLK, &lock); err != nil {
		t.Fatal(err)
	}
	if _, stderr, err := tart.Tart(t, "clone", "source", "destination"); err != nil {
		t.Fatalf("clone after shutdown: %v: %s", err, stderr)
	}
	currentInfo, err := os.Stat(config)
	if err != nil || os.SameFile(originalInfo, currentInfo) {
		t.Fatalf("clone did not replace the stopped destination: %v", err)
	}
}

// Run holds the storage lock while opening VM files. Pause publication at the
// prune lock so we can check storage-lock ownership without timing assumptions.
func TestPublishWaitsForVMLookup(t *testing.T) {
	for _, operation := range []string{"create", "rename"} {
		t.Run(operation, func(t *testing.T) {
			if operation == "create" {
				// Create validates a VM configuration even without booting it.
				// Hosted macOS guests may not expose hardware virtualization.
				supported, err := syscall.SysctlUint32("kern.hv_support")
				if err != nil {
					t.Fatalf("check hypervisor support: %v", err)
				}
				if supported == 0 {
					t.Skip("create requires hardware virtualization; kern.hv_support is 0")
				}
			}

			home := t.TempDir()
			t.Setenv("TART_HOME", home)
			t.Setenv("TART_NO_AUTO_PRUNE", "1")
			createSyntheticVM(t, home, "source", "92:81:b5:ab:39:37")
			destination := createSyntheticVM(t, home, "destination", "92:81:b5:ab:39:38")
			// Rename accepts an incomplete destination. Its manifest makes
			// replacement acquire the content-pruning lock after the PID lock.
			if err := os.Remove(filepath.Join(destination, "disk.img")); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(destination, "manifest.json"), []byte("{}"), 0600); err != nil {
				t.Fatal(err)
			}
			configPath := filepath.Join(destination, "config.json")
			config, err := os.OpenFile(configPath, os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { config.Close() })
			originalInfo, err := config.Stat()
			if err != nil {
				t.Fatal(err)
			}

			prunePath := filepath.Join(home, "cache", "content", ".gc.lock")
			if err := os.MkdirAll(filepath.Dir(prunePath), 0700); err != nil {
				t.Fatal(err)
			}
			prune, err := os.OpenFile(prunePath, os.O_CREATE|os.O_RDWR, 0600)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { prune.Close() })
			if err := syscall.Flock(int(prune.Fd()), syscall.LOCK_EX); err != nil {
				t.Fatal(err)
			}

			storage, err := os.Open(home)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { storage.Close() })
			args := []string{"rename", "source", "destination"}
			if operation == "create" {
				args = []string{"create", "--linux", "--disk-size", "1", "destination"}
			}
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "tart", args...)
			var output bytes.Buffer
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			var waitErr error
			go func() { waitErr = cmd.Wait(); close(done) }()
			defer func() { cancel(); <-done }()

			ticker := time.NewTicker(10 * time.Millisecond)
			defer ticker.Stop()
			for {
				lock := syscall.Flock_t{Type: syscall.F_RDLCK, Whence: 0}
				if err := syscall.FcntlFlock(config.Fd(), syscall.F_GETLK, &lock); err != nil {
					t.Fatal(err)
				}
				if lock.Type == syscall.F_WRLCK && lock.Pid == int32(cmd.Process.Pid) {
					break
				}
				select {
				case <-done:
					t.Fatalf("%s exited before taking the destination PID lock: %v: %s", operation, waitErr, output.String())
				case <-ticker.C:
				}
			}

			// The command has reached replacement and cannot finish while
			// we hold the prune lock. It must already own the storage lock.
			if err := syscall.Flock(int(storage.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
				t.Fatalf("%s reached replacement without holding the storage lock", operation)
			} else if err != syscall.EWOULDBLOCK {
				t.Fatalf("probe storage lock: %v", err)
			}
			if err := syscall.Flock(int(prune.Fd()), syscall.LOCK_UN); err != nil {
				t.Fatal(err)
			}
			<-done
			if waitErr != nil {
				t.Fatalf("%s after releasing the prune lock: %v: %s", operation, waitErr, output.String())
			}
			currentInfo, err := os.Stat(configPath)
			if err != nil || os.SameFile(originalInfo, currentInfo) {
				t.Fatalf("destination was not replaced: %v", err)
			}
		})
	}
}

func createSyntheticVM(t *testing.T, home, name, mac string) string {
	t.Helper()
	directory := filepath.Join(home, "vms", name)
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	config, err := json.Marshal(map[string]any{
		"version": 1, "os": "linux", "arch": runtime.GOARCH,
		"cpuCountMin": 4, "cpuCount": 4,
		"memorySizeMin": 4294967296, "memorySize": 4294967296,
		"macAddress": mac, "diskFormat": "raw",
		"display": map[string]int{"width": 1024, "height": 768},
	})
	if err != nil {
		t.Fatal(err)
	}
	for filename, contents := range map[string][]byte{
		"config.json": config, "disk.img": make([]byte, 4096), "nvram.bin": {},
	} {
		if err := os.WriteFile(filepath.Join(directory, filename), contents, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return directory
}
