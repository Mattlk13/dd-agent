# Datadog Agent v5 - Certificate Update Runbook

## Overview

This runbook helps maintain connectivity for Datadog Agent v5 installations following certificate authority updates.

## Who Is Affected

If you are running **Datadog Agent v5**, particularly versions below **5.32.7**, you may experience connectivity issues with Datadog intake endpoints due to SSL certificate verification failures.

## Why This Matters

Agent v5 uses an embedded certificate bundle for SSL/TLS verification. When Datadog's SSL certificates are updated to use newer certificate authorities, older Agent v5 installations may not recognize these certificates, causing the Agent to lose connectivity with Datadog.

## Solution

This runbook provides automated scripts for both Linux and Windows that will:

1. Download and install an updated certificate bundle
2. Configure the Agent to use your operating system's certificate store as a fallback
3. Restart the Agent and verify connectivity

## Available Scripts

### Which script should I use?

| Your OS | Script to use |
|---|---|
| RHEL / CentOS / Oracle Linux **5 or 6** | [`el5-6/linux.sh`](el5-6/linux.sh) |
| RHEL / CentOS / Oracle Linux **7+** | [`linux.sh`](linux.sh) |
| Ubuntu / Debian / Fedora / any modern distro | [`linux.sh`](linux.sh) |
| Windows Server **2008 R2 or 2012 R2** | [`windows-2008-2012/windows.ps1`](windows-2008-2012/windows.ps1) |
| Windows Server **2016+** | [`windows.ps1`](windows.ps1) |

### `linux.sh` (EL 7+, Ubuntu, Debian, Fedora, and similar)

- **Supported distributions**: Ubuntu/Debian, RHEL/CentOS/Oracle Linux 7+, Fedora, and similar
- **Requirements**: Root or sudo access, `curl` or `wget`

### `el5-6/linux.sh` (RHEL / CentOS / Oracle Linux 5 and 6)

- **Supported distributions**: RHEL 5/6, CentOS 5/6, Oracle Linux 5/6
- **Requirements**: Root or sudo access
- **Extra options**:
  - `-p <agent_directory>` — custom Agent installation path
  - `-c <cert_file>` — path to a local copy of `datadog-cert.pem` for hosts that cannot reach `raw.githubusercontent.com`
- **Compatibility notes**:
  - Works with bash 3.1 (default on EL5) — no associative arrays or bash 4+ features
  - Does not require the `truncate` binary (absent from coreutils 5.97 shipped with EL5)
  - Automatically retries the certificate download without TLS verification if the system CA bundle is too old to verify GitHub (common on EL5); the downloaded certificate is then validated against the Datadog endpoint
  - Skips `journalctl` checks — EL5/6 use SysV init, not systemd

### `windows.ps1` (Windows Server 2016+)

- **Requirements**: PowerShell 3.0 or higher, Administrator privileges
- **Automatic features**: Auto-detects Agent v5 installation path (handles different versions and architectures)

### `windows-2008-2012/windows.ps1` (Windows Server 2008 R2 and 2012 R2)

- **Requirements**: PowerShell 2.0+, .NET 3.5+, Administrator privileges
- **Extra options**:
  - `-AgentDirectory` / `-p` — custom Agent installation path
  - `-CertFile` / `-c` — path to a local copy of `datadog-cert.pem` for hosts that cannot reach `raw.githubusercontent.com`
- **Compatibility notes**:
  - Does not use `Invoke-WebRequest` (PS 3.0+) as primary downloader — uses `System.Net.WebClient` (.NET 2.0) instead, with `Invoke-WebRequest` and BITS as fallbacks
  - Does not use `Get-Content -Raw` (PS 3.0+) — uses `[System.IO.File]::ReadAllText()` (.NET 2.0) instead
  - Does not use `[DateTimeOffset]::ToUnixTimeSeconds()` (.NET 4.6+) — replaced with manual epoch subtraction
  - Does not use `[Environment]::Is64BitOperatingSystem` (.NET 4.0+) — replaced with `[IntPtr]::Size`
  - Forces TLS 1.2 using the raw integer value `3072` instead of the named enum `[Net.SecurityProtocolType]::Tls12` (.NET 4.5+)
  - **Windows 2008 R2 and TLS 1.2**: TLS 1.2 also requires a system-level fix (KB3140245 + SChannel registry changes). Without it, downloads from GitHub will fail. In that case, download `datadog-cert.pem` on another machine and use `-CertFile`.

## How to Use

### Linux (EL 7+, Ubuntu, Debian, Fedora, and similar)

```bash
# Download the script
curl -O https://raw.githubusercontent.com/DataDog/dd-agent/master/runbooks/sectigo-root-ca-rotation-2025/linux.sh

# Make it executable
chmod +x linux.sh

# Run with sudo
sudo ./linux.sh
```

### Linux (RHEL / CentOS / Oracle Linux 5 or 6)

```bash
# Download the script
curl -O https://raw.githubusercontent.com/DataDog/dd-agent/master/runbooks/sectigo-root-ca-rotation-2025/el5-6/linux.sh

# Make it executable
chmod +x linux.sh

# Run with sudo
sudo ./linux.sh
```

If the host **cannot reach GitHub**, download `datadog-cert.pem` on another machine and transfer it manually, then pass it with `-c`:

```bash
sudo ./linux.sh -c /path/to/datadog-cert.pem
```

### Windows (Server 2016+)

```powershell
# Download the script (run as Administrator)
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/DataDog/dd-agent/master/runbooks/sectigo-root-ca-rotation-2025/windows.ps1" -OutFile "windows.ps1"

# Run the script
.\windows.ps1
```

### Windows (Server 2008 R2 or 2012 R2)

`Invoke-WebRequest` is not available on PowerShell 2.0 (default on 2008 R2). Use `System.Net.WebClient` instead:

```powershell
# Download the script (run as Administrator)
(New-Object System.Net.WebClient).DownloadFile(
    "https://raw.githubusercontent.com/DataDog/dd-agent/master/runbooks/sectigo-root-ca-rotation-2025/windows-2008-2012/windows.ps1",
    "$env:TEMP\windows.ps1"
)

# Run the script
& "$env:TEMP\windows.ps1"
```

On **2012 R2** (PS 4.0), `Invoke-WebRequest` is available and can be used instead:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/DataDog/dd-agent/master/runbooks/sectigo-root-ca-rotation-2025/windows-2008-2012/windows.ps1" -OutFile "windows.ps1" -UseBasicParsing
.\windows.ps1
```

If the host **cannot reach GitHub** (or TLS 1.2 is not yet enabled at the OS level on 2008 R2), download `datadog-cert.pem` on another machine, transfer it, then pass it with `-CertFile`:

```powershell
.\windows.ps1 -CertFile "C:\Temp\datadog-cert.pem"
```

## What the Scripts Do

Both scripts perform the following steps automatically:

1. **Download Updated Certificate**: Fetches the latest Datadog certificate bundle
2. **Install Certificate**: Places the certificate in the correct location for your Agent installation
3. **Update Configuration**: Enables `use_curl_http_client: true` in your datadog.conf to allow the Agent to use OS-provided certificates
4. **Restart Agent**: Restarts the Datadog Agent to apply changes
5. **Verify Connectivity**: Checks logs for certificate errors and confirms API key validation

The scripts will output detailed progress information and report any errors encountered.

## Expected Output

When the script completes successfully, you should see:

```
Downloading the DataDog certificate...
Certificate downloaded successfully to [path]
Updating configuration file...
Configuration file updated successfully.
Restarting the DataDog Agent...
Waiting 30 seconds for the DataDog Agent to restart...
=== Connectivity test (since this restart) ===
API key validation: OK
Connectivity test passed: no certificate verification errors since restart.
```

If errors are detected, the script will display a specific error message and prompt you to contact support.

## Important Notes

### Operating System Support

The fallback mechanism (`use_curl_http_client: true`) relies on your operating system's certificate store. If your operating system is no longer receiving security updates (end-of-life), the OS certificate store may not contain the necessary certificates, and connectivity issues may persist.

### Configuration Changes

The script modifies your `/etc/dd-agent/datadog.conf` (Linux) or `C:\ProgramData\Datadog\datadog.conf` (Windows) file. On Windows, a backup is automatically created before modification.

### Network Requirements

The scripts require outbound HTTPS connectivity to:

- `raw.githubusercontent.com` (to download the certificate)

Ensure your firewall allows these connections.

## Troubleshooting

### Script Fails to Download Certificate

Ensure you have network connectivity and your firewall allows outbound HTTPS connections to GitHub.

If the host cannot reach GitHub at all, download `datadog-cert.pem` from another machine and pass it directly to the script:

**Linux (EL5/6)**:
```bash
sudo ./linux.sh -c /path/to/datadog-cert.pem
```

**Windows (2008 R2 / 2012 R2)**:
```powershell
.\windows.ps1 -CertFile "C:\Temp\datadog-cert.pem"
```

### Agent Fails to Restart

Verify the Datadog Agent service is installed and running:

**Linux**:

```bash
sudo service datadog-agent status
```

**Windows**:

```powershell
Get-Service DatadogAgent
```

### Connectivity Test Fails

If certificate errors persist after running the script:

1. Verify your operating system is receiving security updates
2. Check the Agent logs for detailed error messages:
   - Linux: `/var/log/datadog/forwarder.log` and `/var/log/datadog/collector.log`
   - Windows: `C:\ProgramData\Datadog\logs\forwarder.log` and `collector.log`
3. Contact Datadog Support with the script output and log excerpts

### Permission Errors

- **Linux**: Ensure you run the script with `sudo`
- **Windows**: Right-click PowerShell and select "Run as Administrator"

## Verification

After running the script, verify your Agent is reporting metrics:

1. Wait 2-3 minutes for data to appear
2. Check your host in the Datadog Infrastructure List
3. Verify the "Last Seen" timestamp is recent

You can also manually check the Agent status:

**Linux**:

```bash
sudo /etc/init.d/datadog-agent info
```

**Windows** (path may vary):

```powershell
& "C:\Program Files\Datadog\Datadog Agent\agent.exe" info
```

## Long-Term Recommendation

While this runbook provides a working solution, **Datadog strongly recommends upgrading to Datadog Agent v6 or v7** to benefit from:

- Automatic certificate management (no manual intervention needed)
- Ongoing security updates and bug fixes
- Improved performance and new features
- Long-term support

Agent v5 reached end-of-life and no longer receives updates. For migration guidance, visit the [Datadog documentation](https://docs.datadoghq.com/agent/guide/upgrade_agent_fleet_automation).

## Support

If you encounter issues running this runbook or continue experiencing connectivity problems, please contact [Datadog Support](https://www.datadoghq.com/support/) with:

1. Your Agent version
2. Operating system and version
3. Complete output from the script
4. Recent Agent log excerpts showing any errors

## Additional Information

For more information about Datadog Agent installation and configuration, see the [official Datadog documentation](https://docs.datadoghq.com/agent/).
