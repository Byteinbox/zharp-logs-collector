package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// ANSI colour codes — disabled when stdout is not a terminal.
var (
	colBold   = "\033[1m"
	colGreen  = "\033[0;32m"
	colYellow = "\033[1;33m"
	colBlue   = "\033[0;34m"
	colCyan   = "\033[0;36m"
	colDim    = "\033[2m"
	colReset  = "\033[0m"
)

func init() {
	if !isTerminal(os.Stdout) {
		colBold = ""
		colGreen = ""
		colYellow = ""
		colBlue = ""
		colCyan = ""
		colDim = ""
		colReset = ""
	}
}

var stdinReader = bufio.NewReader(os.Stdin)

// uiReadLine reads a single line from stdin.
func uiReadLine() string {
	line, _ := stdinReader.ReadString('\n')
	return strings.TrimRight(line, "\r\n")
}

// uiOK prints a success message.
func uiOK(msg string) {
	fmt.Printf("  %s✓%s  %s\n", colGreen, colReset, msg)
}

// uiInfo prints an info message.
func uiInfo(msg string) {
	fmt.Printf("  %s→%s  %s\n", colBlue, colReset, msg)
}

// uiWarn prints a warning message.
func uiWarn(msg string) {
	fmt.Printf("  %s!%s  %s\n", colYellow, colReset, msg)
}

// uiDimMsg prints a dimmed message.
func uiDimMsg(msg string) {
	fmt.Printf("     %s%s%s\n", colDim, msg, colReset)
}

// uiSection prints a bold section header.
func uiSection(msg string) {
	fmt.Println()
	fmt.Printf("%s%s%s\n", colBold, msg, colReset)
	fmt.Println()
}

// uiHR prints a horizontal rule.
func uiHR() {
	fmt.Printf("  %s──────────────────────────────────────────────────%s\n", colDim, colReset)
}

// uiBanner prints the banner.
func uiBanner() {
	fmt.Println()
	fmt.Printf("%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n", colBold, colReset)
	fmt.Printf("%s       Zharp Collector  ·  Guided Setup            %s\n", colBold, colReset)
	fmt.Printf("%s  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n", colBold, colReset)
	fmt.Println()
}

// uiAsk prints a prompt and returns the user's input.
func uiAsk(prompt string) string {
	fmt.Printf("  %s?%s  %s%s%s ", colCyan, colReset, colBold, prompt, colReset)
	return uiReadLine()
}

// promptDefault calls uiAsk and returns def if the response is empty.
func promptDefault(prompt, def string) string {
	var label string
	if def != "" {
		label = fmt.Sprintf("%s [%s]:", prompt, def)
	} else {
		label = prompt + ":"
	}
	v := strings.TrimSpace(uiAsk(label))
	if v == "" {
		return def
	}
	return v
}
