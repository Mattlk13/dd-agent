#!/bin/bash
# Datadog Agent v5 runbook — Linux (all supported distributions).
# Compatible with bash 3.1+ (RHEL/CentOS/Oracle Linux 5 and 6, EL 7+, Ubuntu, Debian, Fedora, …)
#
# On RHEL/CentOS/Oracle Linux 5 and 6 the script automatically applies compatibility
# adjustments:
#   - Falls back to --insecure / --no-check-certificate if the system CA bundle is too
#     old to verify raw.githubusercontent.com (common on RHEL/CentOS 5); the downloaded
#     certificate is then validated against the Datadog endpoint.
#   - Uses a portable log-truncation fallback (truncate absent from coreutils 5.97 / EL5).
#   - Skips journalctl checks — EL5/6 use SysV init, not systemd.

set -eo pipefail

show_usage() {
  echo "Usage: $0 [-p <agent_directory>] [-c <cert_file>]"
  echo "  -p <agent_directory>  Custom Datadog Agent installation directory"
  echo "                        (default: /opt/datadog-agent/agent)"
  echo "  -c <cert_file>        Path to a local copy of datadog-cert.pem"
  echo "                        Use this when the host cannot reach raw.githubusercontent.com."
  echo "                        The file is copied in place; no download is attempted."
  exit 1
}

while getopts "p:c:h" opt; do
  case $opt in
    p) ARG_AGENT_DIR="$OPTARG" ;;
    c) ARG_CERT_FILE="$OPTARG" ;;
    h) show_usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; show_usage ;;
  esac
done

# -------------------------- Configuration ---------------------------
URL="https://raw.githubusercontent.com/DataDog/dd-agent/master/datadog-cert.pem"

CUSTOM_DD_AGENT_DIR="${ARG_AGENT_DIR:-}"
LOCAL_CERT_FILE="${ARG_CERT_FILE:-}"
CUSTOM_DD_CONFIG_FILE=""
CUSTOM_DD_LOG_DIR=""

if [ -n "$CUSTOM_DD_AGENT_DIR" ]; then
  TARGET_DIR="$CUSTOM_DD_AGENT_DIR"
else
  TARGET_DIR="/opt/datadog-agent/agent"
fi

if [ -n "$CUSTOM_DD_CONFIG_FILE" ]; then
  CONF_FILE="$CUSTOM_DD_CONFIG_FILE"
else
  CONF_FILE="/etc/dd-agent/datadog.conf"
fi

if [ -n "$CUSTOM_DD_LOG_DIR" ]; then
  LOG_FILES="$CUSTOM_DD_LOG_DIR/forwarder.log $CUSTOM_DD_LOG_DIR/collector.log"
else
  LOG_FILES="/var/log/datadog/forwarder.log /var/log/datadog/collector.log"
fi

TARGET_FILE="${TARGET_DIR}/datadog-cert.pem"
DOWNLOADER=""
OS_MAJOR=""
IS_LEGACY_EL=false
PRE_TS_UNIX=""
PRE_TS_READABLE=""

# ------------------------------- Helpers ----------------------------

error_exit() {
  echo "$1" >&2
  echo "Please contact support for further help." >&2
  exit 1
}

detect_os_version() {
  if [ -f /etc/redhat-release ]; then
    local release_line
    release_line="$(cat /etc/redhat-release 2>/dev/null)"
    OS_MAJOR=$(echo "$release_line" | sed 's/.*release \([0-9]\).*/\1/' 2>/dev/null)

    # Identify the specific distro from the release string.
    # All three write to /etc/redhat-release but with different prefixes:
    #   RHEL:          "Red Hat Enterprise Linux * release X.Y (...)"
    #   CentOS:        "CentOS release X.Y (Final)"  [v5]
    #                  "CentOS Linux release X.Y (Core)"  [v6]
    #   Oracle Linux:  "Oracle Linux Server release X.Y"
    #                  "Enterprise Linux Enterprise Linux Server release X.Y"  [early OL5]
    local distro
    case "$release_line" in
      *"Red Hat"*)    distro="RHEL" ;;
      *"CentOS"*)     distro="CentOS" ;;
      *"Oracle"*)     distro="Oracle Linux" ;;
      *"Enterprise"*) distro="Oracle Linux (early release string)" ;;
      *)              distro="Unknown RHEL-based distro" ;;
    esac

    echo "Detected: $distro ${OS_MAJOR:-?} (from: $release_line)"

    if [ "$OS_MAJOR" = "5" ] || [ "$OS_MAJOR" = "6" ]; then
      IS_LEGACY_EL=true
      echo "Note: Applying EL5/6 compatibility mode" \
           "(portable truncation, insecure download fallback, no journalctl)."
    fi
  fi
}

check_downloader() {
  # When a local cert is provided we only need a downloader for verify_certificate.
  # If neither tool is present in that case we skip verification with a warning
  # instead of aborting; the cert came from a trusted local source.
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    if [ -n "$LOCAL_CERT_FILE" ]; then
      echo "Warning: Neither curl nor wget found; skipping connectivity verification."
      DOWNLOADER="none"
    else
      error_exit "Error: Neither curl nor wget found. Please install curl or wget and try again."
    fi
  fi
  echo "Using downloader: $DOWNLOADER"
}

# Portable log truncation.
# RHEL 5 ships coreutils 5.97 which does NOT include the `truncate` binary.
# We fall back to an empty redirect executed via sudo sh -c.
truncate_log_file() {
  local f="$1"
  if command -v truncate >/dev/null 2>&1; then
    sudo truncate -s 0 "$f" 2>/dev/null \
      || echo "  Warning: Could not truncate $f"
  else
    # Works on bash 3.1 + RHEL 5: sudo opens the file for writing via sh, which
    # truncates it to zero bytes without requiring the truncate binary.
    sudo sh -c "> \"$f\"" 2>/dev/null \
      || echo "  Warning: Could not clear $f"
  fi
}

ensure_target_directory() {
  if ! sudo test -d "$TARGET_DIR"; then
    echo "Directory $TARGET_DIR does not exist. Creating it..."
    sudo mkdir -p "$TARGET_DIR" \
      || error_exit "Error: Failed to create $TARGET_DIR."
    if id dd-agent >/dev/null 2>&1; then
      echo "Setting directory ownership to dd-agent:dd-agent..."
      sudo chown dd-agent:dd-agent "$TARGET_DIR" \
        || echo "Warning: Failed to set ownership, but continuing..."
    fi
  fi
}

# Download helper with a two-stage approach for legacy EL5/6:
#   Stage 1 — standard TLS verification (preferred).
#   Stage 2 — skip TLS verification if stage 1 fails; prints a clear warning.
#             Only attempted on EL5/6 where the system CA bundle may predate
#             the DigiCert roots used by GitHub. The cert being retrieved is the
#             Datadog application cert, NOT a system CA, so the integrity risk is
#             limited; verify_certificate() checks usability against the Datadog
#             endpoint afterwards.
download_url() {
  local url="$1"
  local outfile="$2"

  if [ "$DOWNLOADER" = "curl" ]; then
    if sudo curl -fsSL --connect-timeout 30 "$url" -o "$outfile" 2>/dev/null; then
      return 0
    fi
    if [ "$IS_LEGACY_EL" = "true" ]; then
      echo "  Warning: TLS-verified download failed." \
           "System CA bundle on this OS version may be too old to verify raw.githubusercontent.com."
      echo "  Retrying with --insecure. The downloaded certificate will be validated"
      echo "  against the Datadog endpoint in the next step."
      sudo curl -fsSL --insecure --connect-timeout 30 "$url" -o "$outfile" \
        || return 1
    else
      return 1
    fi
  else
    if sudo wget -q --timeout=30 -O "$outfile" "$url" 2>/dev/null; then
      return 0
    fi
    if [ "$IS_LEGACY_EL" = "true" ]; then
      echo "  Warning: TLS-verified download failed." \
           "System CA bundle on this OS version may be too old to verify raw.githubusercontent.com."
      echo "  Retrying with --no-check-certificate. The downloaded certificate will be"
      echo "  validated against the Datadog endpoint in the next step."
      sudo wget -q --no-check-certificate --timeout=30 -O "$outfile" "$url" \
        || return 1
    else
      return 1
    fi
  fi
}

install_local_certificate() {
  echo "Using local certificate file: $LOCAL_CERT_FILE"
  if [ ! -f "$LOCAL_CERT_FILE" ]; then
    error_exit "Error: Local certificate file '$LOCAL_CERT_FILE' not found."
  fi
  sudo cp "$LOCAL_CERT_FILE" "$TARGET_FILE" \
    || error_exit "Error: Failed to copy '$LOCAL_CERT_FILE' to '$TARGET_FILE'."
  echo "Certificate copied successfully to $TARGET_FILE."

  if id dd-agent >/dev/null 2>&1; then
    sudo chown dd-agent:dd-agent "$TARGET_FILE" \
      || echo "Warning: Failed to set certificate ownership, but continuing..."
  fi
  sudo chmod 644 "$TARGET_FILE" \
    || echo "Warning: Failed to set certificate permissions, but continuing..."
}

download_certificate() {
  echo "Downloading the Datadog certificate using $DOWNLOADER..."
  download_url "$URL" "$TARGET_FILE" \
    || error_exit "Error: Failed to download certificate."
  echo "Certificate downloaded successfully to $TARGET_FILE."

  if id dd-agent >/dev/null 2>&1; then
    echo "Setting certificate file ownership to dd-agent:dd-agent..."
    sudo chown dd-agent:dd-agent "$TARGET_FILE" \
      || echo "Warning: Failed to set certificate ownership, but continuing..."
  fi
  sudo chmod 644 "$TARGET_FILE" \
    || echo "Warning: Failed to set certificate permissions, but continuing..."
}

verify_certificate() {
  if [ "$DOWNLOADER" = "none" ]; then
    echo "Skipping connectivity verification (no curl or wget available)."
    echo "The Agent logs will confirm certificate validity after restart."
    return 0
  fi

  echo "Verifying the downloaded certificate..."
  local test_url
  test_url="https://app.datadoghq.com"

  if [ "$DOWNLOADER" = "curl" ]; then
    if sudo curl -fsSL --cacert "$TARGET_FILE" --connect-timeout 10 \
        "$test_url" >/dev/null 2>&1; then
      echo "Certificate verification successful: can connect to Datadog."
    else
      error_exit "Error: Certificate verification failed. Cannot establish SSL connection to $test_url using the downloaded certificate."
    fi
  else
    if sudo wget --ca-certificate="$TARGET_FILE" --timeout=10 \
        -q -O /dev/null "$test_url" 2>/dev/null; then
      echo "Certificate verification successful: can connect to Datadog."
    else
      error_exit "Error: Certificate verification failed. Cannot establish SSL connection to $test_url using the downloaded certificate."
    fi
  fi
}

update_datadog_config() {
  if ! sudo test -f "$CONF_FILE"; then
    error_exit "Error: Configuration file $CONF_FILE not found."
  fi

  echo "Updating $CONF_FILE for use_curl_http_client..."
  if sudo grep -q '^[[:space:]]*use_curl_http_client' "$CONF_FILE"; then
    echo "Parameter 'use_curl_http_client' found. Setting its value to true..."
    sudo sed -i 's/^\([[:space:]]*\)use_curl_http_client.*/\1use_curl_http_client: true/' "$CONF_FILE" \
      || error_exit "Error: Failed to update $CONF_FILE."
  else
    echo "Parameter 'use_curl_http_client' not found. Adding it with value true..."
    echo "use_curl_http_client: true" | sudo tee -a "$CONF_FILE" >/dev/null \
      || error_exit "Error: Failed to update $CONF_FILE."
  fi
  echo "Configuration file updated successfully."
}

rotate_logs() {
  echo "Rotating log files before restart for easier troubleshooting..."
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  for f in $LOG_FILES; do
    if sudo test -f "$f"; then
      local backup
      backup="${f}.pre-cert-update-${timestamp}"
      echo "  Backing up $(basename "$f") to $(basename "$backup")"
      sudo cp "$f" "$backup" 2>/dev/null \
        || echo "  Warning: Could not back up $f"
      truncate_log_file "$f"
    fi
  done
  PRE_TS_UNIX="$(date +%s)"
  PRE_TS_READABLE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Restart timestamp: $PRE_TS_READABLE (epoch: $PRE_TS_UNIX)"
}

restart_agent() {
  echo "Restarting the Datadog Agent..."
  if ! sudo service datadog-agent restart; then
    error_exit "Error: Failed to restart the Datadog agent."
  fi
  echo "Waiting 30 seconds for the Datadog Agent to restart..."
  sleep 30
}

test_connectivity_since_restart() {
  echo "=== Connectivity test (since this restart) ==="
  local pattern
  pattern='CERTIFICATE_VERIFY_FAILED|certificate verify failed|ssl[[:space:][:punct:]]*error'

  # Check the freshly-rotated log files (truncated just before restart).
  for log_file in $LOG_FILES; do
    if sudo test -f "$log_file" && sudo test -s "$log_file"; then
      echo "  Checking $(basename "$log_file")..."
      if sudo grep -qiE "$pattern" "$log_file" 2>/dev/null; then
        echo ""
        echo "ERROR: Detected SSL/cert verification failure in $(basename "$log_file"):"
        sudo grep -iE "$pattern" "$log_file" | head -10
        error_exit "Certificate verification failed. Please review the log at: $log_file"
      fi
    fi
  done

  # journalctl is only available on systemd-based systems (EL 7+, Ubuntu, Debian, …).
  # EL 5 and 6 use SysV init and do not ship journald.
  if [ "$IS_LEGACY_EL" = "false" ] && command -v journalctl >/dev/null 2>&1; then
    echo "  Checking journald logs..."
    # Prefer epoch form; fall back to a readable UTC timestamp if needed.
    local SINCE_ARG
    SINCE_ARG="@${PRE_TS_UNIX}"
    if ! sudo journalctl --since "$SINCE_ARG" -n 0 >/dev/null 2>&1; then
      SINCE_ARG="$PRE_TS_READABLE"
    fi
    if sudo journalctl -u datadog-agent --since "$SINCE_ARG" --no-pager 2>/dev/null | grep -qiE "$pattern"; then
      error_exit "Detected SSL/cert verification failure in journald since restart."
    fi
  fi

  echo "  Checking agent status..."
  if sudo /etc/init.d/datadog-agent info 2>/dev/null | grep -q "API Key is valid"; then
    echo "API key validation: OK"
  else
    echo "Warning: Could not confirm 'API Key is valid' from agent info." >&2
  fi

  echo "Connectivity test passed: no certificate verification errors detected."
  echo ""
  echo "Fresh logs are available at:"
  for log_file in $LOG_FILES; do
    if sudo test -f "$log_file"; then
      echo "  - $log_file"
    fi
  done
}

main() {
  detect_os_version
  check_downloader
  ensure_target_directory
  if [ -n "$LOCAL_CERT_FILE" ]; then
    install_local_certificate
  else
    download_certificate
  fi
  verify_certificate
  update_datadog_config
  rotate_logs
  restart_agent
  test_connectivity_since_restart
}

main
