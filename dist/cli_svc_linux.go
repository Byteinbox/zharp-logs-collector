//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

// svcInstall creates the system user, writes the systemd unit, and starts the service.
func svcInstall(cfg *svcInstallConfig) error {
	// Create system user (ignore error if already exists).
	addUser := exec.Command("useradd", "--system", "--no-create-home", "--shell", "/sbin/nologin", "zharp-collector")
	_ = addUser.Run()

	// Add to log-reading groups.
	exec.Command("usermod", "-aG", "adm", "zharp-collector").Run()             //nolint:errcheck
	exec.Command("usermod", "-aG", "systemd-journal", "zharp-collector").Run() //nolint:errcheck
	if cfg.hasDocker {
		exec.Command("usermod", "-aG", "docker", "zharp-collector").Run() //nolint:errcheck
	}

	// Fix ownership on config dir.
	exec.Command("chown", "-R", "zharp-collector:zharp-collector", "/etc/zharp-collector").Run() //nolint:errcheck

	// Write systemd unit.
	unit := fmt.Sprintf(`[Unit]
Description=Zharp OpenTelemetry Collector
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zharp-collector
ExecStart=%s --config %s
EnvironmentFile=%s
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
`, cfg.binaryPath, cfg.configFile, cfg.envFile)

	if err := os.WriteFile("/etc/systemd/system/zharp-collector.service", []byte(unit), 0o644); err != nil {
		return fmt.Errorf("write systemd unit: %w", err)
	}

	// Reload and enable.
	if out, err := exec.Command("systemctl", "daemon-reload").CombinedOutput(); err != nil {
		return fmt.Errorf("daemon-reload: %w: %s", err, out)
	}
	if out, err := exec.Command("systemctl", "enable", "--now", "zharp-collector").CombinedOutput(); err != nil {
		return fmt.Errorf("enable service: %w: %s", err, out)
	}

	time.Sleep(2 * time.Second)

	if exec.Command("systemctl", "is-active", "--quiet", "zharp-collector").Run() == nil {
		uiOK("Service started and enabled.")
	} else {
		uiWarn("Service may not have started. Check logs:")
		uiDimMsg("sudo journalctl -fu zharp-collector")
	}
	return nil
}

// svcStart starts the zharp-collector systemd service.
func svcStart() error {
	return exec.Command("systemctl", "start", "zharp-collector").Run()
}

// svcStop stops the zharp-collector systemd service.
func svcStop() error {
	return exec.Command("systemctl", "stop", "zharp-collector").Run()
}

// svcStatus shows the systemd service status.
func svcStatus() error {
	cmd := exec.Command("systemctl", "status", "zharp-collector")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// svcLogs tails the service journal.
func svcLogs() error {
	cmd := exec.Command("journalctl", "-fu", "zharp-collector")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// svcUninstall stops, disables, and removes the service and config.
func svcUninstall() error {
	exec.Command("systemctl", "stop", "zharp-collector").Run()             //nolint:errcheck
	exec.Command("systemctl", "disable", "zharp-collector").Run()          //nolint:errcheck
	os.Remove("/etc/systemd/system/zharp-collector.service")               //nolint:errcheck
	exec.Command("systemctl", "daemon-reload").Run()                       //nolint:errcheck
	os.RemoveAll("/etc/zharp-collector")                                   //nolint:errcheck
	exec.Command("userdel", "zharp-collector").Run()                       //nolint:errcheck
	return nil
}

// printDoneCommands prints useful post-install commands for Linux.
func printDoneCommands() {
	uiDimMsg("sudo systemctl status zharp-collector")
	uiDimMsg("sudo journalctl -fu zharp-collector")
	uiDimMsg("sudo zharp-collector logs")
	uiDimMsg("sudo nano " + installConfigFile())
	uiDimMsg("sudo systemctl restart zharp-collector")
}
