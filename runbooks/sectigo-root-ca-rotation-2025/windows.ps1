<# Datadog Agent v5 runbook — Windows (all supported versions).
   Compatible with PowerShell 2.0+ and .NET 3.5+.
   Automatically handles Windows Server 2008 R2, 2012 R2, 2016, and later.

   Compatibility notes:
     - Primary downloader is System.Net.WebClient (.NET 2.0+), so it works on
       Windows 2008 R2 with PS 2.0 where Invoke-WebRequest is not available.
       Invoke-WebRequest and BITS are kept as fallbacks.
     - [System.IO.File]::ReadAllText() is used instead of Get-Content -Raw
       (the -Raw switch requires PS 3.0).
     - TLS 1.2 is forced via the numeric value 3072 instead of the named enum
       [Net.SecurityProtocolType]::Tls12, added in .NET 4.5.
       On Windows 2008 R2 without KB3140245 + SChannel registry fix, TLS 1.2
       is unsupported at the OS level and the download will still fail — see
       the README for details.
     - [DateTimeOffset]::ToUnixTimeSeconds() (added in .NET 4.6) is replaced
       with a manual epoch subtraction.
     - OS architecture is detected via environment variables rather than
       [Environment]::Is64BitOperatingSystem (.NET 4.0+) or [IntPtr]::Size
       (which reports the PowerShell process bitness, not the OS bitness).

.PARAMETER AgentDirectory
   Custom Datadog Agent installation directory.

.PARAMETER CertFile
   Path to a local copy of datadog-cert.pem.
   Use this when the host cannot reach raw.githubusercontent.com.
   The file is copied in place; no download is attempted.

.EXAMPLE
   .\windows.ps1

.EXAMPLE
   .\windows.ps1 -AgentDirectory "D:\Custom\Datadog Agent"

.EXAMPLE
   .\windows.ps1 -CertFile "C:\Temp\datadog-cert.pem"
#>

param(
    [Alias("p")]
    [string]$AgentDirectory = "",

    [Alias("c")]
    [string]$CertFile = ""
)

# -------------------------- Configuration ---------------------------
$CERT_URL = "https://raw.githubusercontent.com/DataDog/dd-agent/master/datadog-cert.pem"
$RESTART_WAIT_SECONDS = 30

$CUSTOM_DD_AGENT_DIR = if ($AgentDirectory) { $AgentDirectory } else { "" }
$LOCAL_CERT_FILE = if ($CertFile) { $CertFile } else { "" }

# ------------------------------ Helpers ------------------------------
function Error-Exit {
    param([string]$Message)
    Write-Error $Message
    Write-Host "Please contact support for further help."
    exit 1
}

function Assert-Admin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Error-Exit "Error: This script must be run as Administrator."
        }
    }
    catch {
        Write-Warning "Could not verify elevation; continuing. If steps fail, re-run elevated."
    }
}

# -------------------------- Path discovery --------------------------
function Get-DdV5-CertPath {
    if ($CUSTOM_DD_AGENT_DIR) {
        if (Test-Path -LiteralPath "$CUSTOM_DD_AGENT_DIR\agent") {
            return "$CUSTOM_DD_AGENT_DIR\agent\datadog-cert.pem"
        }
        else {
            return "$CUSTOM_DD_AGENT_DIR\files\datadog-cert.pem"
        }
    }

    # Detect OS bitness via environment variables — reliable on all PS versions.
    # On a 64-bit OS running 32-bit PowerShell (WOW64), PROCESSOR_ARCHITECTURE is
    # 'x86' but PROCESSOR_ARCHITEW6432 is set to 'AMD64'.
    # [Environment]::Is64BitOperatingSystem requires .NET 4.0 (absent on the default
    # PS 2.0/.NET 3.5 stack on Windows 2008 R2).
    # [IntPtr]::Size reports the current process bitness, not the OS bitness, so a
    # 32-bit PowerShell host on a 64-bit OS would incorrectly return 4.
    $is64 = ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') -or
            ($null -ne $env:PROCESSOR_ARCHITEW6432 -and $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64')

    if ($is64) {
        if (Test-Path "C:\Program Files\Datadog\Datadog Agent\agent") {
            return "C:\Program Files\Datadog\Datadog Agent\agent\datadog-cert.pem"    # >=5.12
        }
        else {
            return "C:\Program Files (x86)\Datadog\Datadog Agent\files\datadog-cert.pem" # <=5.11
        }
    }
    else {
        return "C:\Program Files\Datadog\Datadog Agent\files\datadog-cert.pem"           # <=5.11 32-bit
    }
}

function Get-DdV5-ServiceNames { @("DatadogAgent", "datadogagent") }

function Get-DdV5-ConfigFile {
    return "C:\ProgramData\Datadog\datadog.conf"
}

function Get-DdV5-LogFiles {
    $logDir = "C:\ProgramData\Datadog\logs"
    $candidates = @("$logDir\forwarder.log", "$logDir\collector.log", "$logDir\agent.log")
    $existing = @()
    foreach ($f in $candidates) { if (Test-Path -LiteralPath $f) { $existing += $f } }
    if (@($existing).Count -gt 0) { return $existing } else { return $candidates }
}

# --------------------------- Core actions ---------------------------
function Ensure-Directory {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Host "Directory $Dir does not exist. Creating it..."
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
}

function Enable-Tls12 {
    # Force TLS 1.2 using the raw integer value (3072) instead of the named enum member
    # [Net.SecurityProtocolType]::Tls12, which was only added in .NET 4.5.
    # On Windows 2008 R2 this only takes effect if KB3140245 and the matching SChannel
    # registry keys are also applied; without them the OS SChannel stack does not support
    # TLS 1.2 regardless of the .NET setting.
    try {
        $tls12 = 3072
        $current = [int][Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]($current -bor $tls12)
    }
    catch {
        Write-Warning (("Could not enable TLS 1.2: {0}. On Windows 2008 R2, TLS 1.2 also " +
            "requires KB3140245 and SChannel registry changes.") -f $_.Exception.Message)
    }
}

function Set-CertFilePermissions {
    param([string]$TargetFile)
    try {
        $acl = Get-Acl -LiteralPath $TargetFile
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Users", "Read", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $TargetFile -AclObject $acl
        Write-Host "Certificate file permissions set successfully."
    }
    catch {
        Write-Warning "Could not set certificate permissions: $($_.Exception.Message)"
    }
}

function Download-Certificate {
    param([string]$Url, [string]$TargetFile)
    Write-Host "Downloading the Datadog certificate..."
    Enable-Tls12

    # Stage 1: System.Net.WebClient — available from .NET 2.0, works on PS 2.0.
    # Invoke-WebRequest requires PS 3.0 and is absent on 2008 R2 defaults.
    $downloaded = $false
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $TargetFile)
        $downloaded = $true
    }
    catch {
        Write-Warning "WebClient download failed: $($_.Exception.Message). Trying Invoke-WebRequest..."
    }

    # Stage 2: Invoke-WebRequest (PS 3.0+, available on 2012 R2 and patched 2008 R2).
    if (-not $downloaded) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $TargetFile -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
        }
        catch {
            Write-Warning "Invoke-WebRequest failed: $($_.Exception.Message). Trying BITS..."
        }
    }

    # Stage 3: BITS — available on 2008 R2+ but requires the BITS service to be running.
    if (-not $downloaded) {
        try {
            Start-BitsTransfer -Source $Url -Destination $TargetFile -ErrorAction Stop
            $downloaded = $true
        }
        catch {
            Error-Exit "Error: Failed to download certificate with all available methods."
        }
    }

    if (-not (Test-Path -LiteralPath $TargetFile)) {
        Error-Exit "Error: Download reported success but file not found at $TargetFile."
    }
    Write-Host "Certificate downloaded successfully to $TargetFile."
    Set-CertFilePermissions -TargetFile $TargetFile
}

function Install-LocalCertificate {
    param([string]$SourceFile, [string]$TargetFile)
    Write-Host "Using local certificate file: $SourceFile"
    if (-not (Test-Path -LiteralPath $SourceFile)) {
        Error-Exit "Error: Local certificate file '$SourceFile' not found."
    }
    try {
        Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force -ErrorAction Stop
    }
    catch {
        Error-Exit "Error: Failed to copy '$SourceFile' to '$TargetFile'. $($_.Exception.Message)"
    }
    Write-Host "Certificate copied successfully to $TargetFile."
    Set-CertFilePermissions -TargetFile $TargetFile
}

function Test-Certificate {
    param([string]$CertFile)
    Write-Host "Verifying the installed certificate..."

    # Verify the certificate file is a non-empty PEM file.
    if (-not (Test-Path -LiteralPath $CertFile)) {
        Error-Exit "Error: Certificate file not found at $CertFile after installation."
    }
    # [System.IO.File]::ReadAllText works from .NET 2.0 (Get-Content -Raw requires PS 3.0).
    $content = [System.IO.File]::ReadAllText($CertFile)
    if (-not ($content -match "BEGIN CERTIFICATE")) {
        Error-Exit "Error: $CertFile does not appear to be a valid PEM certificate file."
    }
    Write-Host "Certificate file looks valid (PEM format confirmed)."

    # Connectivity check against the Datadog endpoint.
    # Note: this uses the machine trust store, not the installed cert file, so it
    # confirms network reachability rather than cert correctness. The definitive
    # check is the Agent log scan performed after restart.
    $testUrl = "https://app.datadoghq.com"
    Enable-Tls12
    try {
        $request = [System.Net.WebRequest]::Create($testUrl)
        $request.Timeout = 10000
        $response = $request.GetResponse()
        $response.Close()
        Write-Host "Connectivity check successful: can reach $testUrl."
    }
    catch {
        Write-Warning "Could not reach ${testUrl}: $($_.Exception.Message)"
        Write-Warning "This may be a network restriction, firewall rule, or temporary issue."
        Write-Warning "The certificate has been installed; connectivity will be confirmed after the Agent restarts."
        $script:ConnectivityWarning = $true
    }
}

function Update-DatadogConfig {
    param([string]$ConfFile)
    if (-not (Test-Path -LiteralPath $ConfFile)) { Error-Exit "Error: Configuration file $ConfFile not found." }
    Write-Host "Updating $ConfFile for use_curl_http_client..."

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backup = "$ConfFile.bak-$stamp"
    try { Copy-Item -LiteralPath $ConfFile -Destination $backup -Force } catch { Write-Warning "Backup failed: $($_.Exception.Message)" }

    # [System.IO.File]::ReadAllText works from .NET 2.0 (Get-Content -Raw requires PS 3.0).
    $raw = [System.IO.File]::ReadAllText($ConfFile)
    $lines = $raw -split "`r?`n"
    $filtered = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*#?\s*use_curl_http_client\s*[:=].*$') { continue }
        $filtered += $line
    }
    $filtered += 'use_curl_http_client: true'
    $updated = ($filtered -join "`r`n") + "`r`n"

    try { [System.IO.File]::WriteAllText($ConfFile, $updated, (New-Object System.Text.UTF8Encoding($false))) }
    catch { Error-Exit "Error: Failed to update $ConfFile. $($_.Exception.Message)" }

    Write-Host "Configuration file updated successfully. Backup saved to $backup"
}

function Rotate-Logs {
    param([string[]]$LogFiles)
    Write-Host "Rotating log files before restart for easier troubleshooting..."
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($f in $LogFiles) {
        if (Test-Path -LiteralPath $f) {
            $backup = "$f.pre-cert-update-$timestamp"
            Write-Host ("  Backing up {0} to {1}" -f ([IO.Path]::GetFileName($f)), ([IO.Path]::GetFileName($backup)))
            try { Copy-Item -LiteralPath $f -Destination $backup -Force -ErrorAction Stop }
            catch { Write-Warning "Could not back up ${f}: $($_.Exception.Message)" }
            try { Clear-Content -LiteralPath $f -Force -ErrorAction Stop }
            catch { Write-Warning "Could not truncate ${f}: $($_.Exception.Message)" }
        }
    }

    $PreTs = [DateTime]::UtcNow

    # Manual epoch calculation — avoids [DateTimeOffset]::ToUnixTimeSeconds() which
    # was added in .NET 4.6 and is absent on 2008 R2 (.NET 4.0) and 2012 R2 (.NET 4.5.1).
    $unixEpoch = New-Object System.DateTime(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $epoch = [int]($PreTs - $unixEpoch).TotalSeconds

    Write-Host ("Restart timestamp: {0:yyyy-MM-dd HH:mm:ss} UTC (epoch: {1})" -f $PreTs, $epoch)
}

function Restart-Agent {
    param([string[]]$ServiceNames, [int]$WaitSeconds = 30)
    Write-Host "Restarting the Datadog Agent..."
    $restarted = $false
    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Restart-Service -Name $name -Force -ErrorAction Stop
                $restarted = $true
                break
            }
            catch {
                Error-Exit "Error: Failed to restart service '${name}': $($_.Exception.Message)"
            }
        }
    }
    if (-not $restarted) { Error-Exit "Error: Failed to restart the Datadog Agent (service not found)." }
    Write-Host "Waiting $WaitSeconds seconds for the Datadog Agent to restart..."
    Start-Sleep -Seconds $WaitSeconds
}

function Test-ConnectivitySinceRestart {
    param([string[]]$LogFiles, [regex]$ErrorPattern)
    Write-Host "=== Connectivity test (since this restart) ==="

    foreach ($logPath in $LogFiles) {
        if (Test-Path -LiteralPath $logPath) {
            $fileInfo = Get-Item -LiteralPath $logPath
            if ($fileInfo.Length -gt 0) {
                Write-Host ("  Checking {0}..." -f $fileInfo.Name)
                try {
                    # [System.IO.File]::ReadAllText works from .NET 2.0.
                    # Get-Content -Raw requires PS 3.0 and fails silently on PS 2.0
                    # (returns an array instead of a string, breaking the regex match).
                    $content = [System.IO.File]::ReadAllText($logPath)
                    if ($content -and $ErrorPattern.IsMatch($content)) {
                        Write-Host ""
                        Write-Warning ("Detected SSL/cert verification failure in {0}:" -f $fileInfo.Name)
                        $hits = Select-String -Path $logPath -Pattern $ErrorPattern | Select-Object -First 10
                        $hits | ForEach-Object { Write-Host $_.Line }
                        Write-Warning ("The certificate has been replaced. Please review the log at: {0} and test connectivity manually (see summary below)." -f $logPath)
                        $script:ConnectivityWarning = $true
                    }
                }
                catch {
                    Write-Warning ("Could not read {0}: {1}" -f $logPath, $_.Exception.Message)
                }
            }
        }
    }

    Write-Host "  Checking agent status..."
    if ($CUSTOM_DD_AGENT_DIR) {
        $agentInfoPaths = @(
            "$CUSTOM_DD_AGENT_DIR\agent.exe",
            "$CUSTOM_DD_AGENT_DIR\embedded\agent.exe"
        )
    }
    else {
        $agentInfoPaths = @(
            "C:\Program Files\Datadog\Datadog Agent\agent.exe",
            "C:\Program Files\Datadog\Datadog Agent\embedded\agent.exe",
            "C:\Program Files (x86)\Datadog\Datadog Agent\agent.exe",
            "C:\Program Files (x86)\Datadog\Datadog Agent\embedded\agent.exe"
        )
    }
    $infoOk = $false
    foreach ($p in $agentInfoPaths) {
        if (Test-Path -LiteralPath $p) {
            try {
                $out = & $p info 2>&1
                if ($out -match 'API Key is valid') { $infoOk = $true; break }
            }
            catch { }
        }
    }
    if ($infoOk) { Write-Host "API key validation: OK" } else { Write-Warning "Could not confirm 'API Key is valid' from agent info." }

    if (-not $script:ConnectivityWarning) {
        Write-Host "Connectivity test passed: no certificate verification errors detected."
    }
    Write-Host ""
    Write-Host "Fresh logs are available at:"
    foreach ($logPath in $LogFiles) {
        if (Test-Path -LiteralPath $logPath) { Write-Host ("  - {0}" -f $logPath) }
    }
}

# ------------------------------ Main flow ------------------------------
$script:ConnectivityWarning = $false   # set to $true when a non-fatal connectivity check fails

try {
    Assert-Admin

    $CertPath     = Get-DdV5-CertPath
    $TargetDir    = Split-Path -Path $CertPath -Parent
    $TargetFile   = $CertPath
    $ConfFile     = Get-DdV5-ConfigFile
    $LogFiles     = Get-DdV5-LogFiles
    $ServiceNames = Get-DdV5-ServiceNames

    Write-Host "Using certificate path: $TargetFile"
    Ensure-Directory $TargetDir

    if ($LOCAL_CERT_FILE) {
        Install-LocalCertificate -SourceFile $LOCAL_CERT_FILE -TargetFile $TargetFile
    }
    else {
        Download-Certificate -Url $CERT_URL -TargetFile $TargetFile
    }

    Test-Certificate -CertFile $TargetFile
    Update-DatadogConfig -ConfFile $ConfFile
    Rotate-Logs -LogFiles $LogFiles
    Restart-Agent -ServiceNames $ServiceNames -WaitSeconds $RESTART_WAIT_SECONDS

    $ErrorPattern = [regex]'(?i)CERTIFICATE_VERIFY_FAILED|certificate verify failed|ssl[\s\p{P}]*error'
    Test-ConnectivitySinceRestart -LogFiles $LogFiles -ErrorPattern $ErrorPattern

    Write-Host ""
    Write-Host "=============================="
    if ($script:ConnectivityWarning) {
        Write-Host "DONE - certificate replaced, but connectivity could not be fully verified automatically."
        Write-Host ""
        Write-Host "The Datadog certificate has been installed at: $TargetFile"
        Write-Host "The Agent configuration has been updated and the Agent has been restarted."
        Write-Host ""
        # agent.exe lives two levels above datadog-cert.pem regardless of version:
        #   >=5.12:  ...\Datadog Agent\agent\datadog-cert.pem  → ...\Datadog Agent\agent.exe
        #   <=5.11:  ...\Datadog Agent\files\datadog-cert.pem  → ...\Datadog Agent\agent.exe
        $agentExe = Join-Path (Split-Path -Path (Split-Path -Path $TargetFile -Parent) -Parent) "agent.exe"
        Write-Host "Please verify connectivity manually:"
        Write-Host "  - Check the Datadog Agent service:  Get-Service DatadogAgent"
        Write-Host "  - Run agent info:                   & '$agentExe' info"
        Write-Host "  - Check logs for SSL errors:"
        foreach ($logPath in $LogFiles) { Write-Host "      $logPath" }
        Write-Host ""
        Write-Host "If SSL errors persist, contact support with the log output above."
    }
    else {
        Write-Host "DONE - certificate replaced and connectivity verified successfully."
        Write-Host ""
        Write-Host "The Datadog certificate has been installed at: $TargetFile"
        Write-Host "The Agent configuration has been updated, the Agent has been restarted,"
        Write-Host "and no SSL/certificate errors were detected in the logs."
    }
    Write-Host "=============================="
}
catch {
    Error-Exit $_.Exception.Message
}
