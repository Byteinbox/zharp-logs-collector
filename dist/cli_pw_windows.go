//go:build windows

package main

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// uiReadPassword prints a prompt, disables console echo, reads a line, then restores the console mode.
func uiReadPassword(prompt string) string {
	fmt.Printf("  %s?%s  %s%s%s ", colCyan, colReset, colBold, prompt, colReset)

	handle, err := windows.GetStdHandle(windows.STD_INPUT_HANDLE)
	if err != nil {
		return uiReadLine()
	}

	var origMode uint32
	if err := windows.GetConsoleMode(handle, &origMode); err != nil {
		return uiReadLine()
	}

	// Disable ENABLE_ECHO_INPUT (0x0004).
	noEcho := origMode &^ uint32(windows.ENABLE_ECHO_INPUT)
	_ = windows.SetConsoleMode(handle, noEcho)

	password := uiReadLine()

	// Restore original mode.
	_ = windows.SetConsoleMode(handle, origMode)

	fmt.Println()
	return password
}
