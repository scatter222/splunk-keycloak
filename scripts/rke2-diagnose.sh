#!/usr/bin/env bash
# =============================================================================
# RKE2 OFFLINE DIAGNOSTIC SCRIPT
# Requires: bash, systemctl, journalctl, ss/netstat, ip, df, free, ps
# No internet access required. Run as root for full output.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ISSUES=()
WARNINGS=()
PASS=()

LOG_FILE="/tmp/rke2-diag-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Helpers ───────────────────────────────────────────────────────────────────

header()  { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${RESET}";
            echo -e "${CYAN}${BOLD}  $*${RESET}";
            echo -e "${CYAN}${BOLD}══════════════════════════════════════════${RESET}"; }
section() { echo -e "\n${BOLD}▶ $*${RESET}"; }
ok()      { echo -e "  ${GREEN}[OK]${RESET}    $*"; PASS+=("$*"); }
warn()    { echo -e "  ${YELLOW}[WARN]${RESET}  $*"; WARNINGS+=("$*"); }
fail()    { echo -e "  ${RED}[FAIL]${RESET}  $*"; ISSUES+=("$*"); }
info()    { echo -e "         $*"; }
cmd_exists() { command -v "$1" &>/dev/null; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}WARNING: Not running as root. Some checks will be skipped or incomplete.${RESET}"
    sleep 1
  fi
}

# ── 1. Identify Node Role ─────────────────────────────────────────────────────

detect_role() {
  header "NODE ROLE DETECTION"
  RKE2_ROLE="unknown"

  if systemctl list-unit-files 2>/dev/null | grep -q "rke2-server"; then
    RKE2_ROLE="server"
  elif systemctl list-unit-files 2>/dev/null | grep -q "rke2-agent"; then
    RKE2_ROLE="agent"
  fi

  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    grep -q "^server:" /etc/rancher/rke2/config.yaml 2>/dev/null && RKE2_ROLE="agent"
  fi
  [[ -d /var/lib/rancher/rke2/server/db/etcd ]] && RKE2_ROLE="server"

  info "Detected role : ${BOLD}${RKE2_ROLE}${RESET}"
  RKE2_SERVICE="rke2-${RKE2_ROLE}"
  info "Service unit  : ${RKE2_SERVICE}"
}

# ── 2. Service Status ─────────────────────────────────────────────────────────

check_service() {
  header "SERVICE STATUS"
  for svc in rke2-server rke2-agent; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
      STATE=$(systemctl is-active "$svc" 2>/dev/null || true)
      ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || true)
      section "$svc"
      info "Active:  $STATE"
      info "Enabled: $ENABLED"
      if [[ "$STATE" == "active" ]]; then
        ok "$svc is running"
      elif [[ "$STATE" == "activating" ]]; then
        warn "$svc is still activating — possible slow start or deadlock"
      else
        fail "$svc is NOT running (state: $STATE)"
        info "--- Last 60 lines of journal for $svc ---"
        journalctl -u "$svc" -n 60 --no-pager 2>/dev/null || true
      fi
    fi
  done
}

# ── 3. Configuration Files ────────────────────────────────────────────────────

check_config() {
  header "CONFIGURATION"
  section "Main config"
  CONFIG="/etc/rancher/rke2/config.yaml"
  if [[ -f "$CONFIG" ]]; then
    ok "Config file found: $CONFIG"
    info "--- Contents (token redacted) ---"
    sed 's/\(token:\s*\).*/\1<REDACTED>/' "$CONFIG"
    echo ""

    if grep -qE "^token:|^token-file:" "$CONFIG" 2>/dev/null; then
      ok "Token or token-file defined in config"
    else
      warn "No 'token:' or 'token-file:' in config — required for agents and HA clusters"
    fi

    if grep -qE "^server:" "$CONFIG" 2>/dev/null; then
      SERVER_URL=$(grep "^server:" "$CONFIG" | awk '{print $2}')
      ok "server URL set: $SERVER_URL"
    fi
  else
    warn "No config at $CONFIG (defaults or env vars in use)"
  fi

  section "Registries config"
  REG_CONFIG="/etc/rancher/rke2/registries.yaml"
  if [[ -f "$REG_CONFIG" ]]; then
    ok "registries.yaml present"
    cat "$REG_CONFIG"
  else
    info "No registries.yaml — needed if using a private/mirror registry in offline mode"
  fi

  section "Environment override files"
  for env_file in /etc/default/rke2-server /etc/default/rke2-agent \
                  /etc/sysconfig/rke2-server /etc/sysconfig/rke2-agent; do
    if [[ -f "$env_file" ]]; then
      ok "Found: $env_file"
      cat "$env_file"
    fi
  done
}

# ── 4. Binaries & Airgap Images ───────────────────────────────────────────────

check_binaries() {
  header "BINARIES & OFFLINE IMAGES"

  section "RKE2 binary"
  FOUND_RKE2=false
  for loc in /usr/local/bin/rke2 /usr/bin/rke2; do
    if [[ -x "$loc" ]]; then
      ok "rke2 binary: $loc"
      info "Version: $($loc --version 2>/dev/null || echo 'unable to get version')"
      FOUND_RKE2=true
    fi
  done
  $FOUND_RKE2 || fail "rke2 binary not found in /usr/local/bin or /usr/bin"

  section "Bundled critical binaries"
  for b in kubectl crictl ctr containerd; do
    FOUND=false
    for d in /var/lib/rancher/rke2/bin /usr/local/bin /usr/bin; do
      if [[ -x "$d/$b" ]]; then
        ok "$b found at $d/$b"
        FOUND=true; break
      fi
    done
    $FOUND || warn "$b not found — may not be extracted yet until first successful start"
  done

  section "Airgap image tarballs"
  AIRGAP_DIRS=(
    /var/lib/rancher/rke2/agent/images
    /var/lib/rancher/rke2/server/db
    /var/lib/rancher/rke2
  )
  IMAGE_FOUND=false
  for d in "${AIRGAP_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      SIZE=$(du -sh "$f" 2>/dev/null | cut -f1 || echo "?")
      ok "Airgap tarball: $f ($SIZE)"
      IMAGE_FOUND=true
    done < <(find "$d" -maxdepth 3 \( -name "*.tar" -o -name "*.tar.gz" -o -name "*.tar.zst" \) 2>/dev/null)
  done
  $IMAGE_FOUND || fail "No airgap image tarballs found — OFFLINE mode will fail without pre-loaded images"
}

# ── 5. Containerd / CRI ───────────────────────────────────────────────────────

check_containerd() {
  header "CONTAINERD / CRI"

  section "containerd process"
  if pgrep -x containerd &>/dev/null || pgrep -f "containerd" &>/dev/null; then
    ok "containerd is running"
  else
    fail "containerd process NOT found"
  fi

  section "containerd socket"
  RKE2_SOCK="/run/k3s/containerd/containerd.sock"
  SYS_SOCK="/run/containerd/containerd.sock"
  if [[ -S "$RKE2_SOCK" ]]; then
    ok "RKE2 containerd socket present: $RKE2_SOCK"
  elif [[ -S "$SYS_SOCK" ]]; then
    warn "Only system containerd socket found ($SYS_SOCK) — RKE2 uses its own socket"
  else
    fail "No containerd socket found (checked $RKE2_SOCK and $SYS_SOCK)"
  fi

  section "containerd config"
  CCONFIG="/var/lib/rancher/rke2/agent/etc/containerd/config.toml"
  if [[ -f "$CCONFIG" ]]; then
    ok "containerd config: $CCONFIG"
    cat "$CCONFIG"
  else
    info "containerd config not yet generated at $CCONFIG (normal before first successful start)"
  fi

  section "Loaded images (via crictl)"
  CRICTL=""
  for loc in /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl; do
    [[ -x "$loc" ]] && CRICTL="$loc" && break
  done
  if [[ -n "$CRICTL" ]]; then
    USE_SOCK="$RKE2_SOCK"; [[ ! -S "$USE_SOCK" ]] && USE_SOCK="$SYS_SOCK"
    if [[ -S "$USE_SOCK" ]]; then
      info "Running: $CRICTL --runtime-endpoint unix://${USE_SOCK} images"
      "$CRICTL" --runtime-endpoint "unix://${USE_SOCK}" images 2>/dev/null \
        && ok "crictl image list succeeded" \
        || warn "crictl images returned an error"
    else
      warn "Cannot run crictl — no socket available"
    fi
  else
    warn "crictl not found — cannot verify loaded images"
  fi
}

# ── 6. etcd (server only) ─────────────────────────────────────────────────────

check_etcd() {
  [[ "$RKE2_ROLE" != "server" ]] && return
  header "ETCD"

  section "etcd process"
  if pgrep -f etcd &>/dev/null; then
    ok "etcd process running"
    ps aux | grep "[e]tcd" | head -5
  else
    fail "etcd process NOT found — server cannot function without etcd"
  fi

  section "etcd data directory"
  ETCD_DIR="/var/lib/rancher/rke2/server/db/etcd"
  if [[ -d "$ETCD_DIR" ]]; then
    ok "etcd data dir: $ETCD_DIR"
    du -sh "$ETCD_DIR" 2>/dev/null || true
    SNAPS=$(find "$ETCD_DIR" -name "*.snap" 2>/dev/null | wc -l || echo 0)
    if [[ "$SNAPS" -gt 0 ]]; then
      ok "$SNAPS snapshot file(s) found"
    else
      warn "No .snap files in etcd dir — possible fresh node or data corruption"
    fi
  else
    warn "etcd data directory not found: $ETCD_DIR (normal on fresh install)"
  fi

  section "etcd health via etcdctl"
  ETCDCTL=""
  for loc in /var/lib/rancher/rke2/bin/etcdctl /usr/local/bin/etcdctl; do
    [[ -x "$loc" ]] && ETCDCTL="$loc" && break
  done
  ETCD_TLS="/var/lib/rancher/rke2/server/tls/etcd"
  if [[ -n "$ETCDCTL" && -d "$ETCD_TLS" ]]; then
    ETCDCTL_API=3 "$ETCDCTL" \
      --endpoints=https://127.0.0.1:2379 \
      --cacert="${ETCD_TLS}/server-ca.crt" \
      --cert="${ETCD_TLS}/server-client.crt" \
      --key="${ETCD_TLS}/server-client.key" \
      endpoint health 2>/dev/null \
      && ok "etcd endpoint healthy" \
      || fail "etcd endpoint health check FAILED"
  else
    info "etcdctl or certs not available — skipping live health check"
  fi

  section "etcd-related log entries (last 40 matches)"
  journalctl -u rke2-server -n 300 --no-pager 2>/dev/null \
    | grep -iE "etcd|raft|snapshot|leader|panic|fatal|revision" | tail -40 || true
}

# ── 7. TLS Certificates ───────────────────────────────────────────────────────

check_certs() {
  header "TLS CERTIFICATES"
  CERT_BASE="/var/lib/rancher/rke2/server/tls"

  if [[ ! -d "$CERT_BASE" ]]; then
    warn "TLS dir $CERT_BASE not found — normal on agent-only nodes"
    return
  fi

  NOW_EPOCH=$(date +%s)

  while IFS= read -r -d '' cert; do
    openssl x509 -noout -in "$cert" &>/dev/null 2>&1 || continue
    EXPIRY=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null \
      || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || echo 0)
    DAYS=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    SHORT="${cert#$CERT_BASE/}"
    if [[ "$EXPIRY_EPOCH" -lt "$NOW_EPOCH" ]]; then
      fail "CERT EXPIRED: $SHORT  (expired: $EXPIRY)"
    elif [[ "$DAYS" -lt 30 ]]; then
      warn "Cert expiring in ${DAYS} days: $SHORT"
    else
      ok "Cert valid (${DAYS}d left): $SHORT"
    fi
  done < <(find "$CERT_BASE" -name "*.crt" -print0 2>/dev/null)
}

# ── 8. Networking ─────────────────────────────────────────────────────────────

check_networking() {
  header "NETWORKING"

  section "Critical RKE2 port availability"
  declare -A PORT_MAP=(
    [6443]="Kubernetes API server"
    [9345]="RKE2 supervisor / node join"
    [2379]="etcd client"
    [2380]="etcd peer"
    [10250]="kubelet"
    [10257]="kube-controller-manager"
    [10259]="kube-scheduler"
  )

  if cmd_exists ss; then
    LISTEN=$(ss -tlnp 2>/dev/null)
  elif cmd_exists netstat; then
    LISTEN=$(netstat -tlnp 2>/dev/null)
  else
    LISTEN=""
    warn "Neither ss nor netstat available — skipping port checks"
  fi

  for port in "${!PORT_MAP[@]}"; do
    desc="${PORT_MAP[$port]}"
    if echo "$LISTEN" | grep -qE ":${port}\b"; then
      ok "Port $port open: $desc"
    else
      [[ "$RKE2_ROLE" == "server" ]] \
        && fail "Port $port NOT listening: $desc" \
        || info "Port $port not listening: $desc (may be expected on agent)"
    fi
  done

  section "Network interfaces"
  ip addr show 2>/dev/null || ifconfig 2>/dev/null || true

  section "CNI interfaces (flannel / calico / cilium etc.)"
  ip link show 2>/dev/null | grep -iE "cni|flannel|calico|canal|vxlan|cilium|tunl|weave" \
    || info "No CNI interfaces found — normal before CNI plugin initializes"

  section "Routing table"
  ip route show 2>/dev/null || route -n 2>/dev/null || true

  section "iptables (INPUT & FORWARD)"
  if cmd_exists iptables; then
    echo "--- INPUT ---"
    iptables -L INPUT -n --line-numbers 2>/dev/null | head -30 || true
    echo "--- FORWARD ---"
    iptables -L FORWARD -n --line-numbers 2>/dev/null | head -20 || true
  fi

  section "firewalld status"
  if systemctl is-active firewalld &>/dev/null; then
    warn "firewalld is ACTIVE — ensure ports 6443, 9345, 2379, 2380, 10250 are allowed"
    firewall-cmd --list-all 2>/dev/null || true
  else
    ok "firewalld is not active"
  fi
}

# ── 9. Kernel Modules & sysctl ────────────────────────────────────────────────

check_kernel() {
  header "KERNEL MODULES & OS SETTINGS"

  section "Required kernel modules"
  for mod in br_netfilter overlay ip_tables nf_conntrack xt_conntrack; do
    if lsmod 2>/dev/null | grep -q "^${mod}"; then
      ok "Loaded: $mod"
    elif modinfo "$mod" &>/dev/null 2>&1; then
      warn "Available but NOT loaded: $mod  (try: modprobe $mod)"
    else
      fail "Module not available: $mod"
    fi
  done

  section "Required sysctl settings"
  declare -A NEED_SYSCTL=(
    ["net.bridge.bridge-nf-call-iptables"]="1"
    ["net.bridge.bridge-nf-call-ip6tables"]="1"
    ["net.ipv4.ip_forward"]="1"
    ["vm.overcommit_memory"]="1"
    ["kernel.panic"]="10"
  )
  for key in "${!NEED_SYSCTL[@]}"; do
    expected="${NEED_SYSCTL[$key]}"
    actual=$(sysctl -n "$key" 2>/dev/null || echo "NOT_SET")
    if [[ "$actual" == "$expected" ]]; then
      ok "$key = $actual"
    else
      warn "$key = $actual  (expected $expected)"
    fi
  done

  section "Swap"
  SWAP=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || echo 0)
  if [[ "${SWAP:-0}" -gt 0 ]]; then
    warn "Swap is ON (${SWAP}MB) — Kubernetes typically requires swap disabled or --fail-swap-on=false"
  else
    ok "Swap is disabled"
  fi

  section "SELinux"
  if cmd_exists getenforce; then
    SE=$(getenforce 2>/dev/null || echo "unknown")
    info "SELinux mode: $SE"
    [[ "$SE" == "Enforcing" ]] && warn "SELinux Enforcing — verify RKE2 SELinux policy is installed"
  else
    info "getenforce not found"
  fi

  section "AppArmor"
  if cmd_exists aa-status; then
    aa-status 2>/dev/null | head -10 || true
  else
    info "aa-status not found"
  fi
}

# ── 10. Disk & Filesystem ─────────────────────────────────────────────────────

check_disk() {
  header "DISK & FILESYSTEM"

  section "Disk usage on critical paths"
  for p in /var/lib/rancher /var/lib/rancher/rke2 /run /tmp /etc/rancher /var/log /; do
    [[ -e "$p" ]] || continue
    USAGE=$(df -h "$p" 2>/dev/null | tail -1)
    PCT=$(echo "$USAGE" | awk '{print $5}' | tr -d '%')
    info "$p → $USAGE"
    if [[ "${PCT:-0}" -ge 90 ]]; then
      fail "DISK FULL: ${PCT}% used on $p"
    elif [[ "${PCT:-0}" -ge 75 ]]; then
      warn "Disk ${PCT}% full on $p"
    fi
  done

  section "Inode usage (>= 80%)"
  df -i 2>/dev/null | grep -v tmpfs | awk 'NR>1 && $5+0 >= 80 {print "  WARN inode: " $0}' \
    || info "No inode exhaustion found"

  section "RKE2 data directory breakdown"
  [[ -d /var/lib/rancher/rke2 ]] \
    && du -sh /var/lib/rancher/rke2/* 2>/dev/null | sort -h || true

  section "Read-only mounts (unexpected)"
  mount | grep " ro," | grep -vE "proc|sys|dev|tmpfs|iso|cdrom" \
    && warn "Unexpected read-only mount(s) detected above" \
    || info "No unexpected read-only mounts"
}

# ── 11. Memory & CPU ──────────────────────────────────────────────────────────

check_resources() {
  header "MEMORY & CPU"

  section "Memory overview"
  free -h 2>/dev/null || true
  AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 9999)
  if [[ "${AVAIL_MB:-9999}" -lt 512 ]]; then
    fail "Available memory critically low: ${AVAIL_MB}MB"
  elif [[ "${AVAIL_MB:-9999}" -lt 1024 ]]; then
    warn "Available memory low: ${AVAIL_MB}MB (RKE2 server needs ~2GB+)"
  else
    ok "Available memory: ${AVAIL_MB}MB"
  fi

  section "CPU count"
  CPUS=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)
  [[ "$CPUS" -lt 2 ]] \
    && warn "Only ${CPUS} CPU(s) (RKE2 recommends >= 2)" \
    || ok "${CPUS} CPU(s) available"

  section "Load average"
  uptime 2>/dev/null || cat /proc/loadavg 2>/dev/null || true

  section "Top 15 memory consumers"
  ps aux --sort=-%mem 2>/dev/null | head -16 || true

  section "OOM kill events (dmesg)"
  dmesg 2>/dev/null | grep -iE "oom|out of memory|kill process" | tail -20 \
    || info "No OOM events found in dmesg"
}

# ── 12. Hostname & DNS ────────────────────────────────────────────────────────

check_hostname_dns() {
  header "HOSTNAME & DNS"

  section "Hostname"
  FQDN=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
  SHORT=$(hostname -s 2>/dev/null || echo "unknown")
  info "FQDN:  $FQDN"
  info "Short: $SHORT"

  grep -q "$SHORT" /etc/hosts 2>/dev/null \
    && ok "Hostname '$SHORT' is in /etc/hosts" \
    || warn "Hostname '$SHORT' NOT in /etc/hosts — may cause kubelet registration issues"

  section "/etc/hosts"
  cat /etc/hosts 2>/dev/null || true

  section "/etc/resolv.conf"
  cat /etc/resolv.conf 2>/dev/null || true

  section "systemd-resolved"
  systemctl is-active systemd-resolved &>/dev/null && \
    { info "systemd-resolved active"; resolvectl status 2>/dev/null | head -20 || true; } || \
    info "systemd-resolved not active"
}

# ── 13. Time Sync ─────────────────────────────────────────────────────────────

check_time() {
  header "TIME SYNCHRONIZATION"

  section "System time"
  date 2>/dev/null || true

  section "timedatectl"
  timedatectl 2>/dev/null || true

  section "NTP client status"
  if cmd_exists chronyc; then
    chronyc tracking 2>/dev/null | head -10 || true
  elif cmd_exists ntpq; then
    ntpq -p 2>/dev/null | head -10 || true
  else
    warn "No NTP tool found (chronyc/ntpq) — time drift can cause TLS failures in clusters"
  fi
}

# ── 14. Journal Deep-Dive ─────────────────────────────────────────────────────

check_journals() {
  header "JOURNAL DEEP-DIVE"

  for svc in rke2-server rke2-agent; do
    journalctl -u "$svc" -n 1 &>/dev/null 2>&1 || continue

    section "$svc — Error/Warning keywords (last 500 lines)"
    journalctl -u "$svc" -n 500 --no-pager 2>/dev/null \
      | grep -iE "error|fail|fatal|panic|timeout|refused|denied|certificate|tls|etcd|oom|killed|crash|unavailable|no space|permission" \
      | tail -80 || info "No notable errors in last 500 lines"

    section "$svc — Full last 100 lines"
    journalctl -u "$svc" -n 100 --no-pager 2>/dev/null || true
  done

  section "Kernel (dmesg) hardware/panic errors"
  dmesg 2>/dev/null \
    | grep -iE "error|fail|panic|oom|killed|hardware|mce|taint" | tail -30 \
    || info "No kernel errors in dmesg"
}

# ── 15. Node Token ────────────────────────────────────────────────────────────

check_token() {
  header "NODE TOKEN"
  TOKEN_FILE="/var/lib/rancher/rke2/server/node-token"
  if [[ -f "$TOKEN_FILE" ]]; then
    ok "Server node-token exists: $TOKEN_FILE"
    LEN=$(wc -c < "$TOKEN_FILE" 2>/dev/null || echo 0)
    info "Token length: $LEN bytes"
    [[ "$LEN" -lt 10 ]] && fail "Token file is empty or corrupt (< 10 bytes)"
  else
    [[ "$RKE2_ROLE" == "server" ]] \
      && warn "Server node-token not yet generated (server has not started successfully)" \
      || info "Agent nodes do not generate a node-token"
  fi
}

# ── 16. File Permissions ──────────────────────────────────────────────────────

check_permissions() {
  header "CRITICAL FILE PERMISSIONS"

  section "Key directories and binaries"
  for path in /etc/rancher/rke2 /var/lib/rancher/rke2 /usr/local/bin/rke2; do
    [[ -e "$path" ]] || { info "$path does not exist"; continue; }
    PERM=$(stat -c "%a %U:%G %n" "$path" 2>/dev/null || stat -f "%p %Su:%Sg %N" "$path" 2>/dev/null || echo "unknown")
    info "$PERM"
  done

  section "TLS key ownership"
  if [[ -d /var/lib/rancher/rke2/server/tls ]]; then
    find /var/lib/rancher/rke2/server/tls -name "*.key" -exec ls -la {} \; 2>/dev/null | head -20 || true
  fi
}

# ── 17. Prior Crashes / Core Dumps ───────────────────────────────────────────

check_crashes() {
  header "CRASH HISTORY & CORE DUMPS"

  section "systemd coredumps"
  cmd_exists coredumpctl && coredumpctl list 2>/dev/null | tail -20 || info "coredumpctl not available"

  section "RKE2 log files"
  for logdir in /var/log /var/log/rancher; do
    find "$logdir" -maxdepth 3 -name "*rke2*" 2>/dev/null | while read -r f; do
      info "Log file: $f ($(du -sh "$f" 2>/dev/null | cut -f1))"
      tail -50 "$f" 2>/dev/null || true
      echo "---"
    done
  done
}

# ── 18. Summary & Triage ──────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║             DIAGNOSTIC SUMMARY                   ║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}"

  echo ""
  echo -e "${RED}${BOLD}❌  FAILURES  (${#ISSUES[@]}):${RESET}"
  if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}None — no hard failures detected${RESET}"
  else
    for i in "${ISSUES[@]}"; do echo -e "  ${RED}✗${RESET} $i"; done
  fi

  echo ""
  echo -e "${YELLOW}${BOLD}⚠   WARNINGS  (${#WARNINGS[@]}):${RESET}"
  if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}None${RESET}"
  else
    for w in "${WARNINGS[@]}"; do echo -e "  ${YELLOW}!${RESET} $w"; done
  fi

  echo ""
  echo -e "${GREEN}${BOLD}✓   PASSED  (${#PASS[@]}):${RESET}"
  for p in "${PASS[@]}"; do echo -e "  ${GREEN}✓${RESET} $p"; done

  echo ""
  echo -e "${BOLD}Full log: ${LOG_FILE}${RESET}"

  # ── Triage hints ──────────────────────────────────────────────────────────
  if [[ ${#ISSUES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}── TRIAGE HINTS ───────────────────────────────────────${RESET}"
    for issue in "${ISSUES[@]}"; do
      case "$issue" in
        *"EXPIRED"*|*"expired"*)
          echo -e "  → ${BOLD}Rotate certs:${RESET} rke2 certificate rotate"
          echo -e "    Or: rm -rf /var/lib/rancher/rke2/server/tls && systemctl start rke2-server"
          ;;
        *"etcd"*)
          echo -e "  → ${BOLD}etcd issue:${RESET} check disk space, inspect snapshots"
          echo -e "    Restore: rke2 etcd-snapshot restore --name <snapshot>"
          echo -e "    Logs:    journalctl -u rke2-server -f | grep etcd"
          ;;
        *"NOT running"*|*"not running"*|*"is NOT"*)
          echo -e "  → ${BOLD}Service down:${RESET} systemctl start rke2-server"
          echo -e "    Tail logs:  journalctl -u rke2-server -f"
          ;;
        *"Port"*"NOT"*)
          echo -e "  → ${BOLD}Port blocked:${RESET} check firewalld/iptables and whether the process is up"
          ;;
        *"DISK FULL"*)
          echo -e "  → ${BOLD}Free disk space:${RESET} especially /var/lib/rancher and /run"
          echo -e "    Clean old snapshots: ls /var/lib/rancher/rke2/server/db/snapshots/"
          ;;
        *"memory"*|*"Memory"*)
          echo -e "  → ${BOLD}Low memory:${RESET} kill non-essential workloads or add RAM"
          ;;
        *"containerd"*)
          echo -e "  → ${BOLD}containerd not running:${RESET} check rke2 journal, check /run/k3s/ permissions"
          ;;
        *"airgap"*|*"Airgap"*|*"tarball"*)
          echo -e "  → ${BOLD}Missing offline images:${RESET} copy rke2-images.tar.zst to"
          echo -e "    /var/lib/rancher/rke2/agent/images/ then restart rke2"
          ;;
      esac
    done
    echo ""
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  header "RKE2 OFFLINE DIAGNOSTIC  —  $(date)"
  info "OS      : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -a)"
  info "Kernel  : $(uname -r)"
  info "Hostname: $(hostname)"
  info "Uptime  : $(uptime)"

  check_root
  detect_role
  check_service
  check_config
  check_binaries
  check_containerd
  check_etcd
  check_certs
  check_networking
  check_kernel
  check_disk
  check_resources
  check_hostname_dns
  check_time
  check_journals
  check_token
  check_permissions
  check_crashes
  print_summary
}

main "$@"
