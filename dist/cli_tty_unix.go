//go:build !windows

package main

import (
	"bufio"
	"os"
)

// reopenStdinTTY switches stdin to /dev/tty when the binary is exec'd from a
// non-interactive context (e.g. curl | bash), so interactive prompts work.
func reopenStdinTTY() {
	if isTerminal(os.Stdin) {
		return
	}
	tty, err := os.Open("/dev/tty")
	if err != nil {
		return
	}
	os.Stdin = tty
	stdinReader = bufio.NewReader(tty)
}
