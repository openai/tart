package command

import (
	"github.com/cirruslabs/tart/benchmark/internal/command/fio"
	"github.com/cirruslabs/tart/benchmark/internal/command/stackedoci"
	"github.com/cirruslabs/tart/benchmark/internal/command/xcode"
	"github.com/spf13/cobra"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:           "benchmark",
		SilenceUsage:  true,
		SilenceErrors: true,
	}

	cmd.AddCommand(
		fio.NewCommand(),
		stackedoci.NewCommand(),
		xcode.NewCommand(),
	)

	return cmd
}
