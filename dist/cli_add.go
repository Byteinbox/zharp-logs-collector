package main

import (
	"flag"
	"fmt"
	"os"
	"regexp"
	"runtime"
	"strings"
)

// cliAdd handles `zharp-collector add <type> [flags]`
//
// Examples:
//
//	zharp-collector add postgres --host localhost --port 5432 --user zharp_monitor --password secret --db myapp
//	zharp-collector add docker
//	zharp-collector add logs --path /var/log/myapp/app.log --path /var/log/myapp/error.log
func cliAdd() {
	if runtime.GOOS != "windows" && os.Getuid() != 0 {
		fmt.Fprintln(os.Stderr, "  [!] This command must be run as root. Try: sudo zharp-collector add")
		os.Exit(1)
	}

	if len(os.Args) < 3 {
		printAddUsage()
		os.Exit(1)
	}

	svcType := normalizeAddArg(os.Args[2])
	if svcType == "" {
		fmt.Fprintf(os.Stderr, "  [!] Unknown type %q. Run 'zharp-collector help' to see valid types.\n", os.Args[2])
		os.Exit(1)
	}

	configFile := installConfigFile()
	envFile := installEnvFile()
	if _, err := os.Stat(configFile); err != nil {
		fmt.Fprintf(os.Stderr, "  [!] No config found at %s. Run 'zharp-collector install' first.\n", configFile)
		os.Exit(1)
	}

	// Parse flags for this type.
	args := os.Args[3:] // everything after the type
	receiver, block, logPaths, envVars, err := parseAddArgs(svcType, args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  [!] %v\n", err)
		fmt.Fprintln(os.Stderr)
		printAddTypeUsage(svcType)
		os.Exit(1)
	}

	applyAddition(configFile, envFile, receiver, block, logPaths, envVars)

	uiInfo("Restarting service to apply changes...")
	if err := svcRestart(); err != nil {
		uiWarn("Restart failed: " + err.Error())
		uiDimMsg("Restart manually: zharp-collector restart")
	} else {
		uiOK("Done. Data will appear in your Zharp dashboard within a minute.")
	}
	fmt.Println()
}

// parseAddArgs parses flags for the given type and returns the receiver config.
func parseAddArgs(svcType string, args []string) (receiver, block string, logPaths []string, envVars map[string]string, err error) {
	envVars = map[string]string{}
	fs := flag.NewFlagSet("add "+svcType, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	switch svcType {
	case "pg":
		host := fs.String("host", "localhost", "")
		port := fs.String("port", "5432", "")
		user := fs.String("user", "zharp_monitor", "")
		pass := fs.String("password", "", "")
		db := fs.String("db", "postgres", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		if *pass == "" {
			err = fmt.Errorf("--password is required for postgres")
			return
		}
		receiver = "postgresql"
		block = fmt.Sprintf(`
  postgresql:
    endpoint: %s:%s
    username: %s
    password: "${env:PG_PASSWORD}"
    databases:
      - %s
    collection_interval: 30s
    tls:
      insecure: true
`, *host, *port, *user, *db)
		envVars["PG_PASSWORD"] = *pass

	case "mysql":
		host := fs.String("host", "localhost", "")
		port := fs.String("port", "3306", "")
		user := fs.String("user", "zharp_monitor", "")
		pass := fs.String("password", "", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		if *pass == "" {
			err = fmt.Errorf("--password is required for mysql")
			return
		}
		receiver = "mysql"
		block = fmt.Sprintf(`
  mysql:
    endpoint: %s:%s
    username: %s
    password: "${env:MYSQL_PASSWORD}"
    collection_interval: 30s
`, *host, *port, *user)
		envVars["MYSQL_PASSWORD"] = *pass

	case "redis":
		endpoint := fs.String("endpoint", "localhost:6379", "")
		pass := fs.String("password", "", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		receiver = "redis"
		if *pass != "" {
			block = fmt.Sprintf(`
  redis:
    endpoint: %s
    password: "${env:REDIS_PASSWORD}"
    collection_interval: 30s
`, *endpoint)
			envVars["REDIS_PASSWORD"] = *pass
		} else {
			block = fmt.Sprintf(`
  redis:
    endpoint: %s
    collection_interval: 30s
`, *endpoint)
		}

	case "mongo":
		endpoint := fs.String("endpoint", "localhost:27017", "")
		user := fs.String("user", "zharp_monitor", "")
		pass := fs.String("password", "", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		if *pass == "" {
			err = fmt.Errorf("--password is required for mongo")
			return
		}
		receiver = "mongodb"
		block = fmt.Sprintf(`
  mongodb:
    hosts:
      - endpoint: %s
    username: %s
    password: "${env:MONGO_PASSWORD}"
    collection_interval: 30s
    tls:
      insecure: true
`, *endpoint, *user)
		envVars["MONGO_PASSWORD"] = *pass

	case "docker":
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		endpoint := "unix:///var/run/docker.sock"
		if runtime.GOOS == "windows" {
			endpoint = "npipe:////./pipe/docker_engine"
		}
		receiver = "docker_stats"
		block = fmt.Sprintf(`
  docker_stats:
    endpoint: %s
    collection_interval: 30s
    timeout: 20s
`, endpoint)

	case "nginx_log":
		accessLog := fs.String("access-log", "", "")
		errorLog := fs.String("error-log", "", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		if *accessLog == "" {
			switch runtime.GOOS {
			case "windows":
				*accessLog = `C:\nginx\logs\access.log`
			case "darwin":
				*accessLog = "/usr/local/var/log/nginx/access.log"
			default:
				*accessLog = "/var/log/nginx/access.log"
			}
		}
		logPaths = append(logPaths, *accessLog)
		if *errorLog != "" {
			logPaths = append(logPaths, *errorLog)
		}

	case "apache_log":
		accessLog := fs.String("access-log", "", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		if *accessLog == "" {
			if fileExists("/var/log/httpd/access_log") {
				*accessLog = "/var/log/httpd/access_log"
			} else {
				*accessLog = "/var/log/apache2/access.log"
			}
		}
		logPaths = append(logPaths, *accessLog)

	case "syslog":
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		for _, p := range []string{"/var/log/syslog", "/var/log/messages", "/var/log/auth.log"} {
			if fileExists(p) {
				logPaths = append(logPaths, p)
			}
		}
		if len(logPaths) == 0 {
			err = fmt.Errorf("no syslog files found (/var/log/syslog, /var/log/messages)")
			return
		}

	case "iis_log":
		folder := fs.String("log-folder", `C:\inetpub\logs\LogFiles\`, "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		f := *folder
		if !strings.HasSuffix(f, `\`) {
			f += `\`
		}
		logPaths = append(logPaths, f+`**\*.log`)

	case "custom_log":
		// --path can be repeated
		var paths multiFlag
		fs.Var(&paths, "path", "")
		if e := fs.Parse(args); e != nil {
			err = e
			return
		}
		if len(paths) == 0 {
			err = fmt.Errorf("--path is required (repeat for multiple files)")
			return
		}
		logPaths = []string(paths)
	}

	return receiver, block, logPaths, envVars, nil
}

// multiFlag is a flag.Value that accumulates repeated --flag values.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ", ") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// applyAddition writes the new receiver/logs to the config and env files.
func applyAddition(configFile, envFile, receiver, block string, logPaths []string, envVars map[string]string) {
	if block != "" {
		if err := addReceiverToConfig(configFile, receiver, block); err != nil {
			fmt.Fprintf(os.Stderr, "  [!] Could not update config: %v\n", err)
			os.Exit(1)
		}
	}
	if len(logPaths) > 0 {
		if err := addLogPathsToConfig(configFile, logPaths); err != nil {
			fmt.Fprintf(os.Stderr, "  [!] Could not update log paths: %v\n", err)
			os.Exit(1)
		}
	}
	if len(envVars) > 0 {
		if err := appendEnvVars(envFile, envVars); err != nil {
			uiWarn("Could not update env file: " + err.Error())
		}
	}
	uiOK("Config updated → " + configFile)
}

// addReceiverToConfig inserts a receiver YAML block and appends the receiver
// name to the metrics pipeline receivers list.
func addReceiverToConfig(configFile, receiver, block string) error {
	data, err := os.ReadFile(configFile)
	if err != nil {
		return err
	}
	content := string(data)

	block = strings.TrimRight(block, "\n") + "\n"

	marker := "\nprocessors:"
	if !strings.Contains(content, marker) {
		return fmt.Errorf("could not find processors section in config")
	}
	// Only insert if receiver not already present.
	if !strings.Contains(content, "  "+receiver+":") {
		content = strings.Replace(content, marker, "\n"+block+marker, 1)
	}

	// Append receiver name to the metrics pipeline receivers list.
	re := regexp.MustCompile(`([ \t]+metrics:[ \t]*\r?\n[ \t]+receivers:[ \t]*\[)([^\]]*)\]`)
	content = re.ReplaceAllStringFunc(content, func(m string) string {
		sub := re.FindStringSubmatch(m)
		if len(sub) < 3 {
			return m
		}
		existing := strings.TrimSpace(sub[2])
		for _, r := range strings.Split(existing, ",") {
			if strings.TrimSpace(r) == receiver {
				return m // already present
			}
		}
		if existing == "" {
			return sub[1] + receiver + "]"
		}
		return sub[1] + existing + ", " + receiver + "]"
	})

	return os.WriteFile(configFile, []byte(content), 0o644)
}

// addLogPathsToConfig adds log paths to the filelog receiver, creating the
// receiver and a logs pipeline if they don't exist yet.
func addLogPathsToConfig(configFile string, paths []string) error {
	data, err := os.ReadFile(configFile)
	if err != nil {
		return err
	}
	content := string(data)

	includeLines := ""
	for _, p := range paths {
		includeLines += "      - " + p + "\n"
	}

	if strings.Contains(content, "  filelog:") {
		// Append to existing include list.
		content = strings.Replace(content,
			"    include_file_path:",
			includeLines+"    include_file_path:",
			1)
	} else {
		// Create filelog receiver section.
		filelogBlock := "\n  filelog:\n    include:\n" + includeLines +
			"    include_file_path: true\n    include_file_name: false\n"
		content = strings.Replace(content, "\nprocessors:", filelogBlock+"\nprocessors:", 1)

		// Create logs pipeline if it doesn't exist.
		if !strings.Contains(content, "    logs:") {
			logsPipeline := "    logs:\n" +
				"      receivers: [filelog]\n" +
				"      processors: [memory_limiter, resourcedetection, batch]\n" +
				"      exporters: [zharp]\n"
			content = strings.Replace(content, "    metrics:", logsPipeline+"    metrics:", 1)
		}
	}

	return os.WriteFile(configFile, []byte(content), 0o644)
}

// appendEnvVars adds or updates KEY=VALUE pairs in the env file.
func appendEnvVars(envFile string, vars map[string]string) error {
	existing := ""
	if data, err := os.ReadFile(envFile); err == nil {
		existing = string(data)
	}
	for k, v := range vars {
		line := k + "=" + v
		re := regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(k) + `=.*$`)
		if re.MatchString(existing) {
			existing = re.ReplaceAllString(existing, line)
		} else {
			if existing != "" && !strings.HasSuffix(existing, "\n") {
				existing += "\n"
			}
			existing += line + "\n"
		}
	}
	return os.WriteFile(envFile, []byte(existing), 0o600)
}

// normalizeAddArg maps user-facing type names to internal types.
func normalizeAddArg(arg string) string {
	switch strings.ToLower(arg) {
	case "postgres", "postgresql", "pg":
		return "pg"
	case "mysql", "mariadb":
		return "mysql"
	case "redis":
		return "redis"
	case "mongo", "mongodb":
		return "mongo"
	case "docker":
		return "docker"
	case "logs", "log", "custom", "custom_log":
		return "custom_log"
	case "nginx":
		return "nginx_log"
	case "apache", "httpd":
		return "apache_log"
	case "syslog", "system":
		return "syslog"
	case "iis":
		return "iis_log"
	}
	return ""
}

func printAddUsage() {
	fmt.Println()
	fmt.Println("  Usage: zharp-collector add <type> [flags]")
	fmt.Println()
	fmt.Println("  Types:")
	fmt.Println("    postgres  --host HOST --port PORT --user USER --password PASS --db DB")
	fmt.Println("    mysql     --host HOST --port PORT --user USER --password PASS")
	fmt.Println("    redis     --endpoint HOST:PORT [--password PASS]")
	fmt.Println("    mongo     --endpoint HOST:PORT --user USER --password PASS")
	fmt.Println("    docker")
	fmt.Println("    nginx     [--access-log PATH] [--error-log PATH]")
	fmt.Println("    apache    [--access-log PATH]")
	fmt.Println("    syslog")
	fmt.Println("    iis       [--log-folder PATH]")
	fmt.Println("    logs      --path PATH  (--path can be repeated)")
	fmt.Println()
	fmt.Println("  Examples:")
	fmt.Println(`    sudo zharp-collector add postgres --host localhost --user zharp_monitor --password secret --db myapp`)
	fmt.Println(`    sudo zharp-collector add docker`)
	fmt.Println(`    sudo zharp-collector add logs --path /var/log/myapp/app.log --path /var/log/myapp/error.log`)
	fmt.Println()
}

func printAddTypeUsage(svcType string) {
	switch svcType {
	case "pg":
		fmt.Fprintln(os.Stderr, "  Usage: zharp-collector add postgres --host HOST --port PORT --user USER --password PASS --db DB")
	case "mysql":
		fmt.Fprintln(os.Stderr, "  Usage: zharp-collector add mysql --host HOST --port PORT --user USER --password PASS")
	case "redis":
		fmt.Fprintln(os.Stderr, "  Usage: zharp-collector add redis --endpoint HOST:PORT [--password PASS]")
	case "mongo":
		fmt.Fprintln(os.Stderr, "  Usage: zharp-collector add mongo --endpoint HOST:PORT --user USER --password PASS")
	case "custom_log":
		fmt.Fprintln(os.Stderr, "  Usage: zharp-collector add logs --path /path/to/file.log")
	}
}
