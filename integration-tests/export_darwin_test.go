package integration_test

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestExportOverwriteConfirmation(t *testing.T) {
	for _, tt := range []struct {
		name      string
		input     string
		overwrite bool
	}{
		{name: "EOF"},
		{name: "empty line", input: "\n"},
		{name: "no", input: "no\n"},
		{name: "yes", input: "yes\n", overwrite: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("TART_HOME", home)
			t.Setenv("TART_NO_AUTO_PRUNE", "1")
			createSyntheticVM(t, home, "source", "92:81:b5:ab:39:37")

			directory := t.TempDir()
			destination := filepath.Join(directory, "source.tvm")
			original := []byte("existing archive")
			if err := os.WriteFile(destination, original, 0600); err != nil {
				t.Fatal(err)
			}

			cmd := exec.CommandContext(t.Context(), "tart", "export", "source")
			cmd.Dir = directory
			cmd.Stdin = strings.NewReader(tt.input)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("export: %v: %s", err, output)
			}
			if !strings.Contains(string(output), "are you sure you want to overwrite it?") {
				t.Fatalf("expected overwrite confirmation: %s", output)
			}
			if strings.Contains(string(output), "exporting...") != tt.overwrite {
				t.Fatalf("unexpected export behavior: %s", output)
			}

			current, err := os.ReadFile(destination)
			if err != nil {
				t.Fatal(err)
			}
			changed := !bytes.Equal(original, current)
			if changed != tt.overwrite {
				t.Fatalf("destination changed = %t, want %t", changed, tt.overwrite)
			}
		})
	}
}
