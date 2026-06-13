# Zharp Collector — Windows guided setup
# Run as Administrator:
#   irm https://raw.githubusercontent.com/Byteinbox/zharp-logs-collector/main/setup.ps1 | iex
#
# Or download and run locally:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\setup.ps1

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$REPO       = "Byteinbox/zharp-logs-collector"
$INSTALL_DIR = "C:\Program Files\zharp-collector"
$CONFIG_DIR  = "C:\ProgramData\zharp-collector"
$CONFIG_FILE = "$CONFIG_DIR\config.yaml"
$ENV_FILE    = "$CONFIG_DIR\env.ps1"
$SVC_NAME    = "ZharpCollector"
$EXE_PATH    = "$INSTALL_DIR\zharp-collector.exe"

# ── colours ───────────────────────────────────────────────────────────────────
function ok($msg)      { Write-Host "  [+] $msg" -ForegroundColor Green }
function info($msg)    { Write-Host "  --> $msg" -ForegroundColor Cyan }
function warn($msg)    { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function dim($msg)     { Write-Host "      $msg" -ForegroundColor DarkGray }
function section($msg) { Write-Host; Write-Host $msg -ForegroundColor White; Write-Host }
function ask($prompt)  {
    Write-Host -NoNewline "  [?] $prompt " -ForegroundColor Cyan
    return Read-Host
}

Clear-Host
Write-Host
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
Write-Host "       Zharp Collector  ·  Windows Setup           " -ForegroundColor White
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
Write-Host

# ── step 1: install binary ───────────────────────────────────────────────────
section "1 · Downloading collector"

$VERSION = $env:ZHARP_VERSION
if (-not $VERSION) {
    info "Resolving latest release..."
    $rel = Invoke-RestMethod "https://api.github.com/repos/$REPO/releases/latest"
    $VERSION = $rel.tag_name
}
if (-not $VERSION) { warn "Could not resolve version. Set `$env:ZHARP_VERSION=v1.x.x` and retry."; exit 1 }

$ASSET = "zharp-collector-$VERSION-windows-amd64.exe"
$URL   = "https://github.com/$REPO/releases/download/$VERSION/$ASSET"

info "Downloading zharp-collector $VERSION..."
New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
Invoke-WebRequest -Uri $URL -OutFile $EXE_PATH -UseBasicParsing
ok "Installed -> $EXE_PATH"

# ── step 2: detect running services ───────────────────────────────────────────
section "2 · Scanning this server..."

$detected    = [System.Collections.Generic.List[hashtable]]::new()
$manual      = [System.Collections.Generic.List[hashtable]]::new()
$detected_types = @{}

function svc_running($name) {
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    return $s -and $s.Status -eq "Running"
}
function cmd_exists($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# nginx
if ((cmd_exists "nginx") -or (svc_running "nginx") -or (Test-Path "C:\nginx\logs\access.log")) {
    $detected.Add(@{ label="nginx"; type="nginx_log"; detail="logs at C:\nginx\logs\" })
    $detected_types["nginx_log"] = $true
}
# IIS
if (svc_running "W3SVC") {
    $detected.Add(@{ label="IIS (Web Server)"; type="iis_log"; detail="logs at C:\inetpub\logs\" })
    $detected_types["iis_log"] = $true
}
# PostgreSQL
if ((cmd_exists "psql") -or (svc_running "postgresql") -or (svc_running "postgresql-x64-15")) {
    $detected.Add(@{ label="PostgreSQL"; type="pg"; detail="detected on localhost:5432" })
    $detected_types["pg"] = $true
}
# MySQL
if ((cmd_exists "mysql") -or (svc_running "MySQL") -or (svc_running "MySQL80")) {
    $detected.Add(@{ label="MySQL / MariaDB"; type="mysql"; detail="detected on localhost:3306" })
    $detected_types["mysql"] = $true
}
# Redis
if ((cmd_exists "redis-cli") -or (svc_running "Redis")) {
    $detected.Add(@{ label="Redis"; type="redis"; detail="detected on localhost:6379" })
    $detected_types["redis"] = $true
}
# MongoDB
if ((cmd_exists "mongosh") -or (cmd_exists "mongo") -or (svc_running "MongoDB")) {
    $detected.Add(@{ label="MongoDB"; type="mongo"; detail="detected on localhost:27017" })
    $detected_types["mongo"] = $true
}
# Docker
if ((cmd_exists "docker") -and (docker info 2>$null)) {
    $cnt = (docker ps -q 2>$null | Measure-Object -Line).Lines
    $detected.Add(@{ label="Docker"; type="docker"; detail="$cnt container(s) running" })
    $detected_types["docker"] = $true
}

# manual options not already detected
$allManual = @(
    @{ label="nginx logs";      type="nginx_log"; detail="tail nginx access/error log" },
    @{ label="IIS logs";        type="iis_log";   detail="tail IIS W3C logs" },
    @{ label="PostgreSQL";      type="pg";        detail="database metrics" },
    @{ label="MySQL / MariaDB"; type="mysql";     detail="database metrics" },
    @{ label="Redis";           type="redis";     detail="in-memory store metrics" },
    @{ label="MongoDB";         type="mongo";     detail="database metrics" },
    @{ label="Docker";          type="docker";    detail="container metrics" },
    @{ label="Custom log file"; type="custom_log";detail="any log file path" }
)
foreach ($m in $allManual) {
    if (-not $detected_types.ContainsKey($m.type)) { $manual.Add($m) }
}

# ── state ─────────────────────────────────────────────────────────────────────
$done_types    = @{}
$log_paths     = [System.Collections.Generic.List[string]]::new()
$add_filelog   = $false
$metrics_rcvrs = [System.Collections.Generic.List[string]]::new()
$metrics_rcvrs.Add("hostmetrics")
$extra_blocks  = [System.Text.StringBuilder]::new()
$svc_env_vars  = [System.Collections.Generic.List[string]]::new()  # KEY=VALUE pairs for service registry

function show_menu {
    $options = [System.Collections.Generic.List[hashtable]]::new()

    $has_det = $false
    foreach ($d in $detected) {
        if (-not $done_types.ContainsKey($d.type)) { $has_det = $true; break }
    }
    if ($has_det) {
        Write-Host "  Detected on this server:" -ForegroundColor White
        Write-Host "  ────────────────────────────────────────────────" -ForegroundColor DarkGray
        foreach ($d in $detected) {
            if ($done_types.ContainsKey($d.type)) { continue }
            $options.Add($d)
            $n = $options.Count
            Write-Host ("  [{0}]  {1,-24} {2}" -f $n, $d.label, $d.detail) -ForegroundColor Cyan
        }
    }

    $has_man = $false
    foreach ($m in $manual) {
        if (-not $done_types.ContainsKey($m.type)) { $has_man = $true; break }
    }
    if ($has_man) {
        if ($has_det) { Write-Host }
        Write-Host "  Add manually:" -ForegroundColor White
        Write-Host "  ────────────────────────────────────────────────" -ForegroundColor DarkGray
        foreach ($m in $manual) {
            if ($done_types.ContainsKey($m.type)) { continue }
            $options.Add($m)
            $n = $options.Count
            Write-Host ("  [{0}]  {1,-24} {2}" -f $n, $m.label, $m.detail) -ForegroundColor Cyan
        }
    }

    return ,$options
}

function configure_type($type) {
    Write-Host
    switch ($type) {
        "nginx_log" {
            $p = ask "Access log path [C:\nginx\logs\access.log]:"
            if (-not $p) { $p = "C:\nginx\logs\access.log" }
            $log_paths.Add($p)
            $e = ask "Error log path  [C:\nginx\logs\error.log] (blank to skip):"
            if ($e) { $log_paths.Add($e) }
            $script:add_filelog = $true
            ok "nginx logs configured."
        }
        "iis_log" {
            $p = ask "IIS log folder [C:\inetpub\logs\LogFiles\]:"
            if (-not $p) { $p = "C:\inetpub\logs\LogFiles\" }
            $log_paths.Add("$p**\*.log")
            $script:add_filelog = $true
            ok "IIS logs configured."
        }
        "custom_log" {
            Write-Host "  Enter log file paths one at a time. Blank line to finish." -ForegroundColor DarkGray
            while ($true) {
                $p = ask "Log path (blank to finish):"
                if (-not $p) { break }
                $log_paths.Add($p); ok "Added: $p"
            }
            $script:add_filelog = $true
        }
        "pg" {
            $h  = ask "Host   [localhost]:"   ; if (-not $h)  { $h  = "localhost" }
            $pt = ask "Port   [5432]:"        ; if (-not $pt) { $pt = "5432" }
            $u  = ask "User   [zharp_monitor]:"; if (-not $u)  { $u  = "zharp_monitor" }
            Write-Host -NoNewline "  [?] Password: " -ForegroundColor Cyan
            $ss = Read-Host -AsSecureString
            $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
            $db = ask "Database [postgres]:" ; if (-not $db) { $db = "postgres" }
            $null = $extra_blocks.AppendLine(@"

  postgresql:
    endpoint: ${h}:${pt}
    username: ${u}
    password: "`${env:PG_PASSWORD}"
    databases:
      - ${db}
    collection_interval: 30s
    tls:
      insecure: true
"@)
            $svc_env_vars.Add("PG_PASSWORD=$pass")
            $metrics_rcvrs.Add("postgresql")
            ok "PostgreSQL configured."
            warn "Required — run once as superuser:"
            dim "CREATE USER $u WITH PASSWORD 'your_password';"
            dim "GRANT pg_monitor TO $u;"
        }
        "mysql" {
            $h  = ask "Host   [localhost]:"   ; if (-not $h)  { $h  = "localhost" }
            $pt = ask "Port   [3306]:"        ; if (-not $pt) { $pt = "3306" }
            $u  = ask "User   [zharp_monitor]:"; if (-not $u)  { $u  = "zharp_monitor" }
            Write-Host -NoNewline "  [?] Password: " -ForegroundColor Cyan
            $ss = Read-Host -AsSecureString
            $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
            $null = $extra_blocks.AppendLine(@"

  mysql:
    endpoint: ${h}:${pt}
    username: ${u}
    password: "`${env:MYSQL_PASSWORD}"
    collection_interval: 30s
"@)
            $svc_env_vars.Add("MYSQL_PASSWORD=$pass")
            $metrics_rcvrs.Add("mysql")
            ok "MySQL configured."
        }
        "redis" {
            $ep = ask "Endpoint [localhost:6379]:" ; if (-not $ep) { $ep = "localhost:6379" }
            Write-Host -NoNewline "  [?] Password (blank if none): " -ForegroundColor Cyan
            $ss = Read-Host -AsSecureString
            $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
            if ($pass) {
                $null = $extra_blocks.AppendLine(@"

  redis:
    endpoint: ${ep}
    password: "`${env:REDIS_PASSWORD}"
    collection_interval: 30s
"@)
                $svc_env_vars.Add("REDIS_PASSWORD=$pass")
            } else {
                $null = $extra_blocks.AppendLine(@"

  redis:
    endpoint: ${ep}
    collection_interval: 30s
"@)
            }
            $metrics_rcvrs.Add("redis")
            ok "Redis configured."
        }
        "mongo" {
            $ep = ask "Endpoint [localhost:27017]:" ; if (-not $ep) { $ep = "localhost:27017" }
            $u  = ask "User   [zharp_monitor]:"     ; if (-not $u)  { $u  = "zharp_monitor" }
            Write-Host -NoNewline "  [?] Password: " -ForegroundColor Cyan
            $ss = Read-Host -AsSecureString
            $pass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
            $null = $extra_blocks.AppendLine(@"

  mongodb:
    hosts:
      - endpoint: ${ep}
    username: ${u}
    password: "`${env:MONGO_PASSWORD}"
    collection_interval: 30s
    tls:
      insecure: true
"@)
            $svc_env_vars.Add("MONGO_PASSWORD=$pass")
            $metrics_rcvrs.Add("mongodb")
            ok "MongoDB configured."
        }
        "docker" {
            $null = $extra_blocks.AppendLine(@"

  docker_stats:
    endpoint: npipe:////./pipe/docker_engine
    collection_interval: 30s
    timeout: 20s
"@)
            $metrics_rcvrs.Add("docker_stats")
            ok "Docker container metrics configured."
        }
    }
}

# ── step 3: api key ──────────────────────────────────────────────────────────
section "3 · API Key"
dim "Get yours at: https://app.zharp.io/settings/api-keys"
Write-Host
$API_KEY = ask "Paste your API key:"
if (-not $API_KEY) { Write-Host "API key is required." -ForegroundColor Red; exit 1 }
ok "API key saved."

# ── step 4: selection loop ────────────────────────────────────────────────────
section "4 · What do you want to monitor?"
dim "Host metrics (CPU, memory, disk, network) are always collected."
Write-Host

while ($true) {
    $options = show_menu

    if ($options.Count -eq 0) { ok "All available services configured."; break }

    Write-Host
    $pick = ask "Pick a number to configure, or press Enter to finish:"
    if (-not $pick) { break }

    $n = 0
    if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $options.Count) {
        warn "Enter a number between 1 and $($options.Count), or press Enter to finish."
        Write-Host; continue
    }

    $sel = $options[$n - 1]
    Write-Host
    Write-Host "  Configuring: $($sel.label)" -ForegroundColor White
    configure_type $sel.type
    $done_types[$sel.type] = $true

    Write-Host
    $more = ask "Monitor another service? [Y/n]:"
    if ($more -match "^[Nn]") { break }
    Write-Host
}

# ── step 5: write config ─────────────────────────────────────────────────────
section "5 · Writing config"
New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null

$filelog_block = ""
if ($add_filelog -and $log_paths.Count -gt 0) {
    $includes = ($log_paths | ForEach-Object { "      - $_" }) -join "`n"
    $filelog_block = @"
  filelog:
    include:
$includes
    include_file_path: true
    include_file_name: false

"@
}

$metrics_list = $metrics_rcvrs -join ", "
$pipelines = "  pipelines:"
if ($add_filelog) {
    $pipelines += @"

    logs:
      receivers: [filelog]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [zharp]
"@
}
$pipelines += @"

    metrics:
      receivers: [$metrics_list]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [zharp]
"@

$config = @"
## Zharp Collector config — generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')
## Edit then restart: Restart-Service $SVC_NAME

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

receivers:
  hostmetrics:
    collection_interval: 60s
    scrapers:
      cpu:
      memory:
      disk:
      network:
      load:

$filelog_block$($extra_blocks.ToString())
processors:
  batch:
    send_batch_size: 500
    timeout: 5s
  memory_limiter:
    limit_mib: 128
    spike_limit_mib: 32
    check_interval: 5s
  resourcedetection:
    detectors: [system, env]
    timeout: 5s

exporters:
  zharp:
    api_key: "`${env:ZHARP_API_KEY}"

service:
  extensions: [health_check]
$pipelines
"@

Set-Content -Path $CONFIG_FILE -Value $config -Encoding utf8
ok "Config -> $CONFIG_FILE"

# Write secrets as KEY=VALUE for reference (service reads them from registry, not this file)
$envLines = [System.Collections.Generic.List[string]]::new()
$envLines.Add("ZHARP_API_KEY=$API_KEY")
foreach ($kv in $svc_env_vars) { $envLines.Add($kv) }
Set-Content -Path $ENV_FILE -Value ($envLines -join "`n") -Encoding utf8
ok "Secrets -> $ENV_FILE"

# ── step 6: windows service ──────────────────────────────────────────────────
section "6 · Installing Windows service"

# Remove existing service if present
$existing = Get-Service -Name $SVC_NAME -ErrorAction SilentlyContinue
if ($existing) {
    Stop-Service -Name $SVC_NAME -Force -ErrorAction SilentlyContinue
    sc.exe delete $SVC_NAME | Out-Null
    Start-Sleep -Seconds 2
}

# Register the collector exe directly as a Windows service.
# The binary already implements the Windows Service Control Manager protocol.
$binPath = "`"$EXE_PATH`" --config `"$CONFIG_FILE`""
sc.exe create $SVC_NAME binPath= $binPath start= auto DisplayName= "Zharp Collector" | Out-Null
sc.exe description $SVC_NAME "Zharp OpenTelemetry Collector agent" | Out-Null
sc.exe failure $SVC_NAME reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

# Store environment variables in the service's registry key so they are
# available to the process when Windows starts it (no wrapper script needed).
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$SVC_NAME"
Set-ItemProperty -Path $regPath -Name "Environment" -Value $envLines.ToArray() -Type MultiString

Start-Service -Name $SVC_NAME
Start-Sleep -Seconds 2

$svc = Get-Service -Name $SVC_NAME
if ($svc.Status -eq "Running") {
    ok "Service started."
} else {
    warn "Service did not start. Check logs:"
    dim "Get-EventLog -LogName System -Source 'Service Control Manager' -Newest 20 | Format-List"
}

# ── done ──────────────────────────────────────────────────────────────────────
Write-Host
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
Write-Host "    Done! Zharp Collector is running." -ForegroundColor Green
Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor White
Write-Host
Write-Host "  Config:  $CONFIG_FILE" -ForegroundColor White
Write-Host "  Secrets: $ENV_FILE" -ForegroundColor White
Write-Host
Write-Host "  Useful commands:" -ForegroundColor DarkGray
dim "Get-Service $SVC_NAME"
dim "Restart-Service $SVC_NAME"
dim "Stop-Service $SVC_NAME"
dim "notepad '$CONFIG_FILE'"
Write-Host
Write-Host "  Data will appear in your Zharp dashboard within a minute." -ForegroundColor DarkGray
Write-Host
