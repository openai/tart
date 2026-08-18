package stackedoci

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/gosuri/uitable"
	"github.com/spf13/cobra"
	"go.uber.org/zap"
	"go.uber.org/zap/zapio"
)

var (
	debug        bool
	baseImage    string
	stackedImage string
	insecure     bool
	concurrency  uint
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "stacked-oci",
		Short: "benchmark empty and prewarmed Tart homes for stacked OCI pulls",
		Long: "Warm the registry once, then compare an empty Tart home with one whose " +
			"immutable base has already been materialized by tart clone --stacked. " +
			"Every scenario uses a disposable TART_HOME and leaves the user's Tart home untouched.",
		RunE: run,
	}

	cmd.Flags().BoolVar(&debug, "debug", false, "enable debug logging")
	cmd.Flags().StringVar(&baseImage, "base-image", "", "remote flat OCI image used as the stacked image's base")
	cmd.Flags().StringVar(&stackedImage, "image", "", "remote stacked OCI image to pull and clone")
	cmd.Flags().BoolVar(&insecure, "insecure", false, "connect to the OCI registry via insecure HTTP")
	cmd.Flags().UintVar(&concurrency, "concurrency", 4, "network concurrency passed to tart pull and clone")
	_ = cmd.MarkFlagRequired("base-image")
	_ = cmd.MarkFlagRequired("image")

	return cmd
}

func run(cmd *cobra.Command, _ []string) error {
	if concurrency < 1 {
		return fmt.Errorf("concurrency cannot be less than 1")
	}

	config := zap.NewProductionConfig()
	if debug {
		config.Level = zap.NewAtomicLevelAt(zap.DebugLevel)
	}
	logger, err := config.Build()
	if err != nil {
		return err
	}
	defer func() { _ = logger.Sync() }()

	warmupHome, err := os.MkdirTemp("", "tart-stacked-oci-warmup-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(warmupHome)

	emptyHome, err := os.MkdirTemp("", "tart-stacked-oci-empty-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(emptyHome)

	warmHome, err := os.MkdirTemp("", "tart-stacked-oci-warm-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(warmHome)

	table := uitable.New()
	table.AddRow("Scenario", "Operation", "Time")

	// Warm registry, CDN, and filesystem caches before either measured
	// scenario so their difference reflects Tart's local base reuse.
	if _, err := timedTart(cmd.Context(), logger, warmupHome, pullArguments(stackedImage)...); err != nil {
		return fmt.Errorf("registry warmup failed: %w", err)
	}
	if err := os.RemoveAll(warmupHome); err != nil {
		return fmt.Errorf("removing registry warmup home: %w", err)
	}

	duration, err := timedTart(cmd.Context(), logger, emptyHome, pullArguments(stackedImage)...)
	if err != nil {
		return fmt.Errorf("empty-home stacked pull failed: %w", err)
	}
	table.AddRow("empty", "pull stacked image", duration)

	duration, err = timedTart(cmd.Context(), logger, emptyHome, "clone", stackedImage, "empty-clone")
	if err != nil {
		return fmt.Errorf("empty-home stacked clone failed: %w", err)
	}
	table.AddRow("empty", "clone stacked image", duration)
	if err := os.RemoveAll(emptyHome); err != nil {
		return fmt.Errorf("removing empty home: %w", err)
	}

	duration, err = timedTart(cmd.Context(), logger, warmHome, cloneBaseArguments(baseImage)...)
	if err != nil {
		return fmt.Errorf("base prewarm failed: %w", err)
	}
	table.AddRow("prewarmed", "clone --stacked base image", duration)

	duration, err = timedTart(cmd.Context(), logger, warmHome, pullArguments(stackedImage)...)
	if err != nil {
		return fmt.Errorf("prewarmed stacked pull failed: %w", err)
	}
	table.AddRow("prewarmed", "pull stacked image", duration)

	duration, err = timedTart(cmd.Context(), logger, warmHome, "clone", stackedImage, "warm-clone")
	if err != nil {
		return fmt.Errorf("prewarmed stacked clone failed: %w", err)
	}
	table.AddRow("prewarmed", "clone stacked image", duration)

	fmt.Println(table.String())
	return nil
}

func pullArguments(image string) []string {
	args := []string{"pull", "--concurrency", fmt.Sprint(concurrency)}
	if insecure {
		args = append(args, "--insecure")
	}
	return append(args, image)
}

func cloneBaseArguments(image string) []string {
	args := []string{"clone", "--stacked", "--concurrency", fmt.Sprint(concurrency)}
	if insecure {
		args = append(args, "--insecure")
	}
	return append(args, image, "prewarmed-base")
}

func timedTart(
	ctx context.Context,
	logger *zap.Logger,
	tartHome string,
	args ...string,
) (time.Duration, error) {
	logger.Sugar().Debugf("TART_HOME=%s tart %s", tartHome, strings.Join(args, " "))
	start := time.Now()

	command := exec.CommandContext(ctx, "tart", args...)
	command.Env = append(os.Environ(), "TART_HOME="+tartHome)
	loggerWriter := &zapio.Writer{Log: logger, Level: zap.DebugLevel}
	command.Stdout = loggerWriter
	command.Stderr = loggerWriter

	err := command.Run()
	return time.Since(start).Round(time.Millisecond), err
}
