//go:build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
)

// uiReadPassword prints a prompt, disables terminal echo, reads a line, then restores echo.
func uiReadPassword(prompt string) string {
	fmt.Printf("  %s?%s  %s%s%s ", colCyan, colReset, colBold, prompt, colReset)

	// Disable echo.
	stty := exec.Command("stty", "-echo")
	stty.Stdin = os.Stdin
	_ = stty.Run()

	password := uiReadLine()

	// Restore echo.
	sttyOn := exec.Command("stty", "echo")
	sttyOn.Stdin = os.Stdin
	_ = sttyOn.Run()

	fmt.Println()
	return password
}
