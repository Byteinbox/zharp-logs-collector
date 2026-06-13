//go:build windows

package main

// reopenStdinTTY is a no-op on Windows; the curl|bash scenario does not apply.
func reopenStdinTTY() {}
