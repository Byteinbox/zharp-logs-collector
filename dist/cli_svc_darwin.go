//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	launchdLabel = "io.zharp.collector"
	plistFile    = "/Library/LaunchDaemons/io.zharp.collector.plist"
)

// svcInstall installs the launchd daemon on macOS.
func svcInstall(cfg *svcInstallConfig) error {
	// Unload existing (ignore error).
	exec.Command("launchctl", "unload", "-w", plistFile).Run() //nolint:errcheck

	// Build EnvironmentVariables XML.
	var envXML strings.Builder
	for k, v := range cfg.envVars {
		v = strings.ReplaceAll(v, "&", "&amp;")
		v = strings.ReplaceAll(v, "<", "&lt;")
		v = strings.ReplaceAll(v, ">", "&gt;")
		v = strings.ReplaceAll(v, "\"", "&quot;")
		fmt.Fprintf(&envXML, "        <key>%s</key>\n        <string>%s</string>\n", k, v)
	}

	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
        <string>--config</string>
        <string>%s</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
%s    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/zharp-collector.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/zharp-collector.log</string>
</dict>
</plist>
`, launchdLabel, cfg.binaryPath, cfg.configFile, envXML.String())

	if err := os.WriteFile(plistFile, []byte(plist), 0o644); err != nil {
		return fmt.Errorf("write plist: %w", err)
	}

	exec.Command("chmod", "644", plistFile).Run() //nolint:errcheck

	if out, err := exec.Command("launchctl", "load", "-w", plistFile).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl load: %w: %s", err, out)
	}

	time.Sleep(2 * time.Second)

	if exec.Command("launchctl", "list", launchdLabel).Run() == nil {
		uiOK("Service loaded (launchd).")
	} else {
		uiWarn("Service may not have started. Check logs:")
		uiDimMsg("sudo tail -f /var/log/zharp-collector.log")
		uiDimMsg("sudo launchctl list " + launchdLabel)
	}
	return nil
}

// svcStart starts the launchd service.
func svcStart() error {
	return exec.Command("launchctl", "start", launchdLabel).Run()
}

// svcStop stops the launchd service.
func svcStop() error {
	return exec.Command("launchctl", "stop", launchdLabel).Run()
}

// svcStatus shows launchd service info.
func svcStatus() error {
	cmd := exec.Command("launchctl", "list", launchdLabel)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// svcLogs tails the collector log file.
func svcLogs() error {
	cmd := exec.Command("tail", "-f", "/var/log/zharp-collector.log")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// svcUninstall removes the launchd daemon and config.
func svcUninstall() error {
	exec.Command("launchctl", "unload", "-w", plistFile).Run() //nolint:errcheck
	os.Remove(plistFile)                                       //nolint:errcheck
	os.RemoveAll("/etc/zharp-collector")                       //nolint:errcheck
	return nil
}

// svcRestart reloads the launchd daemon.
func svcRestart() error {
	exec.Command("launchctl", "unload", "-w", plistFile).Run() //nolint:errcheck
	return exec.Command("launchctl", "load", "-w", plistFile).Run()
}

// printDoneCommands prints useful post-install commands for macOS.
func printDoneCommands() {
	uiDimMsg("sudo launchctl list " + launchdLabel)
	uiDimMsg("sudo launchctl unload -w " + plistFile + " && sudo launchctl load -w " + plistFile)
	uiDimMsg("sudo tail -f /var/log/zharp-collector.log")
	uiDimMsg("sudo nano " + installConfigFile())
}
