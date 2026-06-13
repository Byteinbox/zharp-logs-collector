package main

import (
	"fmt"
	"os"
)

// handleSubcommand checks os.Args[1] and dispatches CLI subcommands.
// Returns true if a subcommand was handled (caller should return early).
func handleSubcommand() bool {
	if len(os.Args) < 2 {
		return false
	}
	switch os.Args[1] {
	case "install":
		cliInstall()
		return true
	case "start":
		if err := svcStart(); err != nil {
			fmt.Fprintf(os.Stderr, "  [!] start failed: %v\n", err)
			os.Exit(1)
		}
		return true
	case "stop":
		if err := svcStop(); err != nil {
			fmt.Fprintf(os.Stderr, "  [!] stop failed: %v\n", err)
			os.Exit(1)
		}
		return true
	case "status":
		if err := svcStatus(); err != nil {
			fmt.Fprintf(os.Stderr, "  [!] status failed: %v\n", err)
			os.Exit(1)
		}
		return true
	case "logs":
		if err := svcLogs(); err != nil {
			fmt.Fprintf(os.Stderr, "  [!] logs failed: %v\n", err)
			os.Exit(1)
		}
		return true
	case "uninstall":
		cliUninstall()
		return true
	case "help", "--help", "-h":
		cliHelp()
		return true
	}
	return false
}

// cliHelp prints usage information.
func cliHelp() {
	fmt.Println()
	fmt.Println("  Usage: zharp-collector <subcommand>")
	fmt.Println()
	fmt.Println("  Subcommands:")
	fmt.Println("    install    Guided setup wizard — installs config and system service")
	fmt.Println("    start      Start the zharp-collector system service")
	fmt.Println("    stop       Stop the zharp-collector system service")
	fmt.Println("    status     Show service status")
	fmt.Println("    logs       Tail service logs")
	fmt.Println("    uninstall  Remove service and config")
	fmt.Println()
	fmt.Println("  Without a subcommand the collector daemon runs directly.")
	fmt.Println()
}
