#!/usr/bin/env bash
#
# VM setup script — hardened baseline with auto-updates and Claude Code.
# Supports Ubuntu, Debian, and Amazon Linux.
# Run as a regular user with sudo access (not root).
# Prerequisites: sudo must be installed (Debian minimal: run `su -c "apt install sudo"` first).
#
# Supports resume after reboot or cancellation: tracks completed steps and
# picks up where it left off. Safe to re-run at any point.
#
# One-liner: curl -fsSL https://YOUR_HOST/setup-vm.sh -o ~/setup-vm.sh && bash ~/setup-vm.sh

set -euo pipefail

# ── Preflight: required commands ──────────────────────────────────────────
# curl + sudo are not installed by the script but used from step 1 onward.
# On Debian minimal, neither is installed; bail early with a clear message.
for __cmd in bash sudo curl realpath systemctl; do
  if ! command -v "$__cmd" >/dev/null 2>&1; then
    echo "Error: required command '$__cmd' not found." >&2
    echo "       Install it before running this script. On Debian minimal:" >&2
    echo "         su -c \"apt update && apt install -y sudo curl\"" >&2
    exit 1
  fi
done

SCRIPT_PATH="$(realpath "$0")"
STATE_FILE="$HOME/.setup-vm-state"
SKIP_FILE="$HOME/.setup-vm-skip"
# Sentinel recording that we created ~/.bash_profile, so cleanup can remove an
# otherwise-empty one (a stray .bash_profile shadows ~/.profile on login).
BASHPROFILE_SENTINEL="$HOME/.setup-vm-created-bash-profile"
RESUME_MARKER="# __setup-vm-resume__"
# Derive the username from the kernel's idea of the real user (id -un), not the
# $USER env var, which can be unset, stale, or spoofed — and is interpolated
# into a sudoers filename below. Validate it exists before we trust it.
USERNAME="$(id -un)"
if ! getent passwd "$USERNAME" >/dev/null 2>&1; then
  echo "Error: could not resolve current username ('$USERNAME') in passwd." >&2
  exit 1
fi
# Snapshots captured before state files are deleted on completion, so the exit
# summary can still report the real total and label skipped steps correctly.
COMPLETED_SNAPSHOT=""
SKIP_SNAPSHOT=""

# Refuse to run when $0 is not a regular file (e.g. `curl | bash`). Resume
# hooks and self-deletion both depend on a stable on-disk path.
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "Error: this script must be run from a file, not piped from stdin." >&2
  echo "       Run: curl -fsSL <url> -o ~/setup-vm.sh && bash ~/setup-vm.sh" >&2
  exit 1
fi

# Single-instance lock: the resume hook re-runs this on every interactive login,
# so two concurrent SSH sessions after a reboot could both resume and race on the
# state file. Hold an exclusive, non-blocking lock for the life of the process
# (auto-released on exit). Placed before the EXIT trap is installed, so bailing
# here needs no trap teardown. flock is part of util-linux (effectively always
# present); skip the guard rather than fail if it somehow isn't.
if command -v flock &>/dev/null; then
  exec 9>"$HOME/.setup-vm.lock"
  if ! flock -n 9; then
    echo "Another setup-vm.sh instance is already running — exiting." >&2
    exit 0
  fi
fi

# ── Detect package manager and distro ────────────────────────────────────────
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
else
  echo "Error: No supported package manager found (apt, dnf, yum)." >&2
  exit 1
fi

# shellcheck disable=SC1091  # runtime system file, not present at lint time
. /etc/os-release
DISTRO_ID="${ID}"
DISTRO_VERSION_ID="${VERSION_ID:-}"

# DEBIAN_FRONTEND=noninteractive (passed through sudo) suppresses debconf/ncurses
# prompts that -y alone does not answer; the Dpkg conf-* options keep existing
# config files on upgrade so package config conflicts can't stall the run.
pkg_update() {
  case "$PKG_MGR" in
    apt) sudo apt update \
           && sudo DEBIAN_FRONTEND=noninteractive apt -y \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade ;;
    dnf) sudo dnf upgrade -y ;;
    yum) sudo yum update -y ;;
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt) sudo DEBIAN_FRONTEND=noninteractive apt install -y "$@" ;;
    dnf) sudo dnf install -y "$@" ;;
    yum) sudo yum install -y "$@" ;;
  esac
}

# Adds an RPM repo via the native config-manager subcommand, falling back to the
# standalone yum-config-manager binary present on older yum-only systems.
add_rpm_repo() {
  sudo "$PKG_MGR" config-manager --add-repo "$1" 2>/dev/null \
    || sudo yum-config-manager --add-repo "$1"
}

# ── Step definitions ─────────────────────────────────────────────────────────
STEP_LABELS=(
  [1]="System update"
  [2]="Essential packages"
  [3]="Docker Engine"
  [4]="Auto-updates"
  [5]="SSH hardening"
  [6]="Firewall"
  [7]="fail2ban"
  [8]="Passwordless sudo"
  [9]="Tailscale"
  [10]="GitHub CLI"
  [11]="GitHub auth + Git config"
  [12]="Node.js LTS"
  [13]="PATH setup"
  [14]="Claude Code"
  [15]="Claude Code authentication"
  [16]="GabAI bootstrap"
  [17]="Code directory"
  [18]="tmux configuration"
)
# Derive from the label array so adding a step can't desync the counter.
TOTAL_STEPS=${#STEP_LABELS[@]}

MENU_ITEMS=(
  "3|Docker Engine + Compose"
  "4|Auto-updates (all packages, auto-reboot 3am local)"
  "5|SSH hardening (disable root login + password auth)"
  "6|Firewall (deny incoming, rate-limit SSH)"
  "7|fail2ban (SSH brute-force protection)"
  "8|Passwordless sudo for current user"
  "9|Tailscale (mesh VPN with SSH enabled)"
  "10|GitHub CLI + auth + git identity"
  "12|Node.js LTS (via NodeSource repo)"
  "14|Claude Code (AI coding assistant)"
)

# ── State management ───────────────────────────────────────────────────────
get_step() { local s; s="$(cat "$STATE_FILE" 2>/dev/null)"; echo "${s:-0}"; }
set_step() { echo "$1" > "$STATE_FILE"; }
step_done() { [ "$(get_step)" -ge "$1" ]; }
mark_skipped() { grep -qx "$1" "$SKIP_FILE" 2>/dev/null || echo "$1" >> "$SKIP_FILE"; }
# Reads the live skip file during the run; falls back to the snapshot captured
# before cleanup so the exit summary can still label skipped steps correctly.
step_skipped() {
  if [ -f "$SKIP_FILE" ]; then
    grep -qx "$1" "$SKIP_FILE" 2>/dev/null
  else
    printf '%s\n' "$SKIP_SNAPSHOT" | grep -qx "$1" 2>/dev/null
  fi
}

install_resume_hook() {
  if ! grep -qF "$RESUME_MARKER" "$HOME/.bash_profile" 2>/dev/null; then
    # If ~/.bash_profile doesn't exist yet, record that we created it so cleanup
    # can remove it again — otherwise an empty .bash_profile would permanently
    # shadow ~/.profile on Debian/Ubuntu login shells.
    [ -e "$HOME/.bash_profile" ] || : > "$BASHPROFILE_SENTINEL"
    # Ensure the hook lands on its own line: if a pre-existing .bash_profile has
    # no trailing newline, the heredoc would concatenate the `case` onto the
    # user's last line — malforming the hook AND making remove_resume_hook's
    # `grep -vF` strip that whole combined line (deleting the user's content).
    if [ -s "$HOME/.bash_profile" ] && [ -n "$(tail -c1 "$HOME/.bash_profile")" ]; then
      printf '\n' >> "$HOME/.bash_profile"
    fi
    # Guard on an interactive shell ($- contains 'i'): a bare login hook would
    # also fire on non-interactive login shells (ssh host 'cmd', scp/rsync),
    # where the script's `read` prompts hit EOF and abort under set -e, breaking
    # the user's actual remote command. Resume only re-runs on a real login.
    cat >> "$HOME/.bash_profile" <<EOF
case \$- in *i*) [ -f "$STATE_FILE" ] && bash "$SCRIPT_PATH";; esac $RESUME_MARKER
EOF
  fi
}

remove_resume_hook() {
  if [ -f "$HOME/.bash_profile" ]; then
    # Strip our hook line with a fixed-string filter (no sed delimiter to break
    # on, no temp file to leak), truncating in place to preserve the file's perms.
    local filtered
    filtered="$(grep -vF "$RESUME_MARKER" "$HOME/.bash_profile" 2>/dev/null || true)"
    if [ -n "$filtered" ]; then
      printf '%s\n' "$filtered" > "$HOME/.bash_profile"
    else
      : > "$HOME/.bash_profile"
    fi
    # If we created .bash_profile and nothing else is left in it, remove it so
    # it doesn't keep shadowing ~/.profile.
    if [ -f "$BASHPROFILE_SENTINEL" ] && [ ! -s "$HOME/.bash_profile" ]; then
      rm -f "$HOME/.bash_profile"
    fi
  fi
  rm -f "$BASHPROFILE_SENTINEL" "$STATE_FILE" "$SKIP_FILE"
}

reboot_if_needed() {
  local needs_reboot=false
  if [ -f /var/run/reboot-required ]; then
    needs_reboot=true
  elif command -v needs-restarting &>/dev/null && ! needs-restarting -r &>/dev/null; then
    needs_reboot=true
  fi
  if [ "$needs_reboot" = true ]; then
    echo ""
    echo "==> Reboot required (likely kernel upgrade). Rebooting in 5 seconds..."
    echo "    The setup will resume automatically on next login."
    install_resume_hook
    sleep 5
    sudo reboot
    exit 0
  fi
}

# ── Summary on exit ────────────────────────────────────────────────────────
print_summary() {
  local completed
  # On a successful run the state file is deleted before this trap fires, so
  # prefer the snapshot captured just before cleanup; fall back to the live file.
  completed="${COMPLETED_SNAPSHOT:-$(get_step)}"
  echo ""
  echo "============================================"
  echo "  Setup summary"
  echo "============================================"
  for i in $(seq 1 "$TOTAL_STEPS"); do
    if step_skipped "$i"; then
      echo "  [skip]  $i. ${STEP_LABELS[$i]}"
    elif [ "$i" -le "$completed" ]; then
      echo "  [done]  $i. ${STEP_LABELS[$i]}"
    else
      echo "  [    ]  $i. ${STEP_LABELS[$i]}"
    fi
  done
  echo "============================================"
  if [ "$completed" -ge "$TOTAL_STEPS" ]; then
    echo "  All steps complete!"
  else
    echo "  Re-run to continue from step $((completed + 1))."
    echo "  bash $SCRIPT_PATH"
  fi
  echo "============================================"
}
# Clean up the step-5 sshd_config backup temp files on ANY exit (set -e abort,
# SIGINT) — the normal path rm's them inline, but an interruption between mktemp
# and that rm would otherwise leave copies of sshd_config in /tmp. Vars are
# user-owned and `${VAR:-}`-guarded (unset before step 5 runs).
trap 'rm -f "${SSHD_PREEDIT_BACKUP:-}" "${SSHD_BACKUP:-}" 2>/dev/null || true; print_summary' EXIT

# ── Interactive menu ─────────────────────────────────────────────────────────
show_menu() {
  local menu_size=${#MENU_ITEMS[@]}
  local cursor=0
  local -a selected
  for ((i=0; i<menu_size; i++)); do selected[i]=1; done

  echo ""
  echo "============================================"
  echo "  VM Setup Script"
  echo "============================================"
  echo ""
  echo "  This script sets up a fresh Linux VM with"
  echo "  a hardened, production-ready baseline:"
  echo ""
  echo "  - System update + essential packages"
  echo "  - Security hardening (SSH, firewall, fail2ban)"
  echo "  - Auto-updates with scheduled reboots"
  echo "  - Docker, Node.js, GitHub CLI"
  echo "  - Tailscale mesh VPN"
  echo "  - Claude Code AI assistant"
  echo ""
  echo "  Detected: ${DISTRO_ID} (${PKG_MGR})"
  echo ""
  echo "  Prerequisites:"
  echo "    - GitHub account (free: https://github.com/signup)"
  echo "    - Tailscale account (free: https://tailscale.com)"
  echo "  If you don't have these yet, uncheck those"
  echo "  steps below and re-run the script later."
  echo ""
  echo "  Use the menu below to customize."
  echo "  Core steps (system update, essentials, PATH, Claude token,"
  echo "  GabAI plugins, ~/code, tmux) always run and can't be unchecked."
  echo ""
  echo "  Controls:"
  echo "    Up/Down  Move cursor"
  echo "    Space    Toggle item"
  echo "    a        Toggle all"
  echo "    Enter    Confirm and start"
  echo "    q        Quit"
  echo ""

  draw_menu() {
    if [ "${1:-}" = "redraw" ]; then
      printf '\033[%dA' "$menu_size"
    fi
    for ((i=0; i<menu_size; i++)); do
      local label="${MENU_ITEMS[$i]#*|}"
      local mark=" "
      if [ "${selected[i]}" -eq 1 ]; then mark="x"; fi
      if [ "$i" -eq "$cursor" ]; then
        printf '\033[1m  > [%s] %s\033[0m\n' "$mark" "$label"
      else
        printf '    [%s] %s\n' "$mark" "$label"
      fi
    done
  }

  draw_menu

  while true; do
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        read -rsn2 rest
        case "$rest" in
          '[A') ((cursor > 0)) && ((cursor--)) ;;
          # Pre-increment: ((cursor++)) returns the *old* value, which is 0 (a
          # non-zero exit) on the first Down-press and aborts under set -e.
          '[B') ((cursor < menu_size - 1)) && ((++cursor)) ;;
        esac
        ;;
      ' ')
        if [ "${selected[cursor]}" -eq 1 ]; then
          selected[cursor]=0
        else
          selected[cursor]=1
        fi
        ;;
      'a')
        local all_on=1
        for ((i=0; i<menu_size; i++)); do
          if [ "${selected[i]}" -eq 0 ]; then all_on=0; break; fi
        done
        for ((i=0; i<menu_size; i++)); do
          if [ "$all_on" -eq 1 ]; then selected[i]=0; else selected[i]=1; fi
        done
        ;;
      ''|$'\n')
        break
        ;;
      'q')
        echo ""
        echo "Aborted."
        trap - EXIT
        exit 0
        ;;
    esac
    draw_menu redraw
  done

  local -A selected_steps
  for ((i=0; i<menu_size; i++)); do
    local step_num="${MENU_ITEMS[$i]%%|*}"
    if [ "${selected[i]}" -eq 1 ]; then
      selected_steps[$step_num]=1
    fi
  done

  if [ "${selected_steps[10]:-0}" -eq 1 ]; then
    selected_steps[11]=1
  fi

  # Claude Code installs globally via npm, so it needs Node.js (step 12).
  if [ "${selected_steps[14]:-0}" -eq 1 ]; then
    selected_steps[12]=1
  fi

  # firewalld (dnf/yum hosts) has no built-in SSH rate limiting — UFW's `limit`
  # has no equivalent there — so it leans on fail2ban. If the firewall is on,
  # force fail2ban on too, or those hosts get no brute-force throttling at all.
  if { [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; } && [ "${selected_steps[6]:-0}" -eq 1 ]; then
    selected_steps[7]=1
  fi

  : > "$SKIP_FILE"
  for i in $(seq 1 "$TOTAL_STEPS"); do
    case "$i" in 1|2|13|15|16|17|18) continue ;; esac
    if [ "$i" -eq 11 ] && [ "${selected_steps[10]:-0}" -eq 0 ]; then
      echo "$i" >> "$SKIP_FILE"
      continue
    fi
    if [ "${selected_steps[$i]:-0}" -ne 1 ]; then
      echo "$i" >> "$SKIP_FILE"
    fi
  done

  echo ""
  echo "==> Starting setup for user: ${USERNAME}"
  echo ""
}

# ── Show menu on first run, skip on resume ────────────────────────────────
STEP="$(get_step)"
if [ "$STEP" -eq 0 ]; then
  show_menu
elif [ "$STEP" -lt "$TOTAL_STEPS" ]; then
  echo "==> Resuming setup from step $((STEP + 1)): ${STEP_LABELS[$((STEP + 1))]:-unknown}"
fi

# ── Helper: run or skip ──────────────────────────────────────────────────────
run_step() {
  local n=$1
  if step_done "$n"; then return 0; fi
  if step_skipped "$n"; then
    echo "    [skip] $n. ${STEP_LABELS[$n]}"
    set_step "$n"
    return 0
  fi
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# STEPS
# ══════════════════════════════════════════════════════════════════════════════

# ── 1. System update ────────────────────────────────────────────────────────
if ! step_done 1; then
  echo "==> [1/$TOTAL_STEPS] Updating system packages..."
  pkg_update
  set_step 1
fi

# ── 2. Essential packages ───────────────────────────────────────────────────
if ! step_done 2; then
  echo "==> [2/$TOTAL_STEPS] Installing essentials..."
  case "$PKG_MGR" in
    apt)
      pkg_install tmux python3 python3-pip python3-venv python3-dev \
        fail2ban curl wget git sqlite3 ufw ca-certificates gnupg \
        openssh-server update-notifier-common
      ;;
    dnf|yum)
      # EPEL is needed for fail2ban and other extras. Handling differs per distro:
      #   AL2       → amazon-linux-extras install epel
      #   AL2023    → EPEL is not available; fail2ban must come from elsewhere
      #   RHEL 9/10 → need CRB enabled, then epel-release from EPEL
      #   Fedora    → epel-release not needed
      FAIL2BAN_PKG="fail2ban"
      if [ "$DISTRO_ID" = "amzn" ] && [ "$DISTRO_VERSION_ID" = "2" ]; then
        pkg_install amazon-linux-extras 2>/dev/null || true
        sudo amazon-linux-extras install epel -y 2>/dev/null || pkg_install epel-release 2>/dev/null || true
      elif [ "$DISTRO_ID" = "amzn" ] && [ "$DISTRO_VERSION_ID" = "2023" ]; then
        # AL2023 has no EPEL and no fail2ban in default repos.
        echo "    [warn] Amazon Linux 2023 has no EPEL — fail2ban will be skipped."
        FAIL2BAN_PKG=""
      elif [ "$DISTRO_ID" = "rhel" ] || [ "$DISTRO_ID" = "rocky" ] || [ "$DISTRO_ID" = "almalinux" ]; then
        # CRB (CodeReady Builder) provides build deps some EPEL packages need.
        # `crb` is the Rocky/Alma alias; RHEL names it codeready-builder-for-rhel-N-ARCH-rpms.
        # Try both (best-effort; config-manager itself may be absent on minimal hosts).
        sudo dnf config-manager --set-enabled crb 2>/dev/null \
          || sudo dnf config-manager --set-enabled "codeready-builder-for-rhel-${DISTRO_VERSION_ID%%.*}-$(arch)-rpms" 2>/dev/null \
          || true
        pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${DISTRO_VERSION_ID%%.*}.noarch.rpm" 2>/dev/null \
          || pkg_install epel-release 2>/dev/null || true
      else
        pkg_install epel-release 2>/dev/null || true
      fi
      pkg_install tmux python3 python3-pip python3-devel \
        curl wget git sqlite ca-certificates gnupg2 \
        openssh-server yum-utils firewalld
      # fail2ban is installed separately and non-fatally: EPEL setup above is
      # best-effort (2>/dev/null || true), so on a host where it never enabled,
      # folding fail2ban into the main list would hard-fail this whole step under
      # set -e. A failure here just means no brute-force throttling (warned inline below).
      if [ -n "$FAIL2BAN_PKG" ]; then
        pkg_install "$FAIL2BAN_PKG" \
          || echo "    [warn] fail2ban install failed (EPEL unavailable?) — SSH brute-force throttling will be inactive."
      fi
      ;;
  esac
  # Enable lingering so user-level systemd services (nanoclaw, akiflow-sync,
  # nanoclaw-rag) start at boot and persist without an active login session.
  if command -v loginctl &>/dev/null; then
    sudo loginctl enable-linger "${USERNAME}" || echo "    [warn] enable-linger failed — user services may not persist"
  fi
  set_step 2
  # Step 1 may have pulled in a kernel update — reboot before touching the
  # firewall/fail2ban so their kernel modules match the running kernel.
  reboot_if_needed
fi

# ── 3. Docker Engine + Compose ──────────────────────────────────────────────
if ! run_step 3; then
  echo "==> [3/$TOTAL_STEPS] Installing Docker..."
  case "$PKG_MGR" in
    apt)
      # Docker only publishes repos under ubuntu/ and debian/. Map derivatives
      # (Linux Mint, Pop!_OS, etc.) to their base via ID_LIKE so the repo URL
      # doesn't 404; fall back to the raw ID for ubuntu/debian themselves.
      case "$DISTRO_ID" in
        ubuntu|debian) DOCKER_DISTRO="$DISTRO_ID" ;;
        *)
          case " ${ID_LIKE:-} " in
            *" ubuntu "*) DOCKER_DISTRO="ubuntu" ;;
            *" debian "*) DOCKER_DISTRO="debian" ;;
            *) DOCKER_DISTRO="$DISTRO_ID" ;;
          esac
          ;;
      esac
      # Both guarded with :- so an unset VERSION_CODENAME can't abort under set -u.
      DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      if [ -z "$DOCKER_CODENAME" ]; then
        echo "    [warn] could not determine distro codename — skipping Docker install"
        # Record the skip so the exit summary shows [skip], not a misleading
        # [done], for a step that installed nothing.
        mark_skipped 3
      else
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        # Keep the deb entry on one line so no continuation indentation leaks
        # into the written sources file.
        DOCKER_ARCH="$(dpkg --print-architecture)"
        echo "deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${DOCKER_CODENAME} stable" \
          | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        # Enable+start explicitly for parity with the dnf/yum branch (don't rely
        # on the .deb's systemd preset, which a hardened image may have disabled).
        sudo systemctl enable --now docker
      fi
      ;;
    dnf|yum)
      if [ "$DISTRO_ID" = "amzn" ] && [ "$DISTRO_VERSION_ID" = "2023" ]; then
        # AL2023: Amazon maintains its own docker package; Docker CE's centos
        # repo has no 2023/ tree and 404s.
        pkg_install docker
        pkg_install docker-compose-plugin 2>/dev/null \
          || pkg_install docker-compose 2>/dev/null \
          || echo "    [warn] no docker-compose package available on AL2023 — install manually if needed"
      else
        add_rpm_repo https://download.docker.com/linux/centos/docker-ce.repo
        pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      fi
      sudo systemctl enable --now docker
      ;;
  esac
  if getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker "${USERNAME}"
    echo "    Note: docker group membership takes effect on next login."
  else
    echo "    [warn] docker group missing — Docker may not have installed; skipping group add."
  fi
  set_step 3
fi

# ── 4. Auto-updates ─────────────────────────────────────────────────────────
if ! run_step 4; then
  echo "==> [4/$TOTAL_STEPS] Configuring auto-updates..."
  case "$PKG_MGR" in
    apt)
      pkg_install unattended-upgrades
      sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE

      sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'UUCONF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}:${distro_codename}-backports";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
UUCONF
      ;;
    dnf)
      pkg_install dnf-automatic
      sudo sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
      sudo sed -i 's/^upgrade_type.*/upgrade_type = default/' /etc/dnf/automatic.conf
      sudo systemctl enable --now dnf-automatic.timer
      ;;
    yum)
      pkg_install yum-cron
      sudo sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/yum/yum-cron.conf
      sudo sed -i 's/^update_cmd.*/update_cmd = default/' /etc/yum/yum-cron.conf
      sudo systemctl enable --now yum-cron
      ;;
  esac

  # unattended-upgrades reboots at 3am on apt; the RPM auto-update tools have no
  # built-in scheduled reboot, so add a 3am cron that reboots only when needed.
  if [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
    # The cron.d drop-in below is useless without a running cron daemon, and
    # minimal RPM images often ship without cronie — install it (best-effort)
    # so the scheduled reboot actually fires.
    pkg_install cronie 2>/dev/null || echo "    [warn] could not install cronie — the 3am auto-reboot cron may not run."
    sudo systemctl enable --now crond 2>/dev/null || true
    echo '0 3 * * * root command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1 && /sbin/reboot' \
      | sudo tee /etc/cron.d/setup-vm-auto-reboot > /dev/null
  fi

  # Timezone governs when that 3am reboot fires. Prompt, defaulting to Eastern.
  echo ""
  echo "    Select the system timezone (sets when the 3am auto-update reboot runs):"
  echo "      1) America/New_York     (US Eastern)  [default]"
  echo "      2) America/Chicago      (US Central)"
  echo "      3) America/Denver       (US Mountain)"
  echo "      4) America/Los_Angeles  (US Pacific)"
  echo "      5) UTC"
  echo "      6) Europe/London"
  echo "      7) Europe/Paris"
  echo "      8) Asia/Jerusalem"
  echo "      9) Other (enter an IANA name, e.g. Australia/Sydney)"
  read -rp "    Choice [1]: " __tz_choice
  case "${__tz_choice:-1}" in
    1)    TIMEZONE="America/New_York" ;;
    2)    TIMEZONE="America/Chicago" ;;
    3)    TIMEZONE="America/Denver" ;;
    4)    TIMEZONE="America/Los_Angeles" ;;
    5)    TIMEZONE="UTC" ;;
    6)    TIMEZONE="Europe/London" ;;
    7)    TIMEZONE="Europe/Paris" ;;
    8)    TIMEZONE="Asia/Jerusalem" ;;
    9)    read -rp "    Enter IANA timezone name: " TIMEZONE ;;
    *)    echo "    Unrecognized choice — using America/New_York"; TIMEZONE="America/New_York" ;;
  esac
  if ! sudo timedatectl set-timezone "${TIMEZONE:-}" 2>/dev/null; then
    echo "    [warn] '${TIMEZONE:-}' is not a valid timezone — falling back to America/New_York"
    TIMEZONE="America/New_York"
    # Guarded so a systemd-less host (minimal container, WSL) can't abort here.
    sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null \
      || echo "    [warn] could not set timezone (timedatectl unavailable?)"
  fi
  echo "    Timezone set to ${TIMEZONE}."
  set_step 4
fi

# ── 5. SSH hardening ────────────────────────────────────────────────────────
if ! run_step 5; then
  echo "==> [5/$TOTAL_STEPS] Hardening SSH..."
  # Lockout guard: refuse to disable password auth if the current user has
  # no authorized_keys entries. This is the only step that can lock the
  # user out of a fresh VM, so we check even though it's slightly paranoid.
  AUTH_KEYS="$HOME/.ssh/authorized_keys"
  SSH_PROCEED=1
  if [ ! -s "$AUTH_KEYS" ]; then
    echo ""
    echo "    WARNING: ${AUTH_KEYS} is missing or empty."
    echo "    Disabling password auth right now could lock you out."
    echo ""
    read -rp "    Continue anyway? [y/N] " __ssh_ok
    if [[ ! "$__ssh_ok" =~ ^[Yy]$ ]]; then
      # Be truthful about recovery: this step is recorded done, so simply
      # re-running won't re-offer it (and on a full successful run the script
      # self-deletes). To harden later, add a key to $AUTH_KEYS and either set
      # PermitRootLogin/PasswordAuthentication to no in /etc/ssh/sshd_config.d
      # by hand, or reset state (rm ~/.setup-vm-state ~/.setup-vm-skip) and
      # re-download + re-run before it completes.
      echo "    Skipping SSH hardening (no SSH key present)."
      echo "    To harden later: add a key to ${AUTH_KEYS}, then set"
      echo "    PermitRootLogin no / PasswordAuthentication no in /etc/ssh manually"
      echo "    (re-running this script will NOT re-offer this step)."
      mark_skipped 5
      SSH_PROCEED=0
    fi
  fi
  if [ "$SSH_PROCEED" -eq 1 ]; then
    # sshd_config.d is supported on modern distros; fall back to main config
    if [ -d /etc/ssh/sshd_config.d ]; then
      HARDENING_CONF=/etc/ssh/sshd_config.d/99-hardening.conf
      sudo tee "$HARDENING_CONF" > /dev/null <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
      # Older sshd builds predate KbdInteractiveAuthentication and reject it. If
      # validation fails, rewrite without that line so we don't break sshd now
      # or on the next reboot.
      if ! sudo sshd -t 2>/dev/null; then
        sudo tee "$HARDENING_CONF" > /dev/null <<'SSHD'
PermitRootLogin no
PasswordAuthentication no
SSHD
      fi
    else
      # No sshd_config.d on this host. Replace an existing directive, or append
      # it if absent (a bare sed would silently skip keys that aren't present).
      _set_sshd() {  # key value
        if sudo grep -qE "^#?[[:space:]]*$1\b" /etc/ssh/sshd_config; then
          sudo sed -i "s/^#\?[[:space:]]*$1.*/$1 $2/" /etc/ssh/sshd_config
        else
          echo "$1 $2" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        fi
      }
      # Full pre-edit backup so the final gate can FULLY revert this path (the
      # in-place edits below would otherwise be left on disk on a validation
      # failure, making the final gate's "reverted" message untruthful here).
      SSHD_PREEDIT_BACKUP="$(mktemp)"
      sudo cp /etc/ssh/sshd_config "$SSHD_PREEDIT_BACKUP"
      _set_sshd PermitRootLogin no
      _set_sshd PasswordAuthentication no
      # Back up before the KbdInteractive edit so we can revert just that line
      # (keeping the root/password hardening) if this sshd is too old to parse it.
      SSHD_BACKUP="$(mktemp)"
      sudo cp /etc/ssh/sshd_config "$SSHD_BACKUP"
      _set_sshd KbdInteractiveAuthentication no
      if ! sudo sshd -t 2>/dev/null; then
        sudo cp "$SSHD_BACKUP" /etc/ssh/sshd_config
      fi
      rm -f "$SSHD_BACKUP"
    fi
    # Final gate: never restart on a config that doesn't validate.
    if ! sudo sshd -t 2>/dev/null; then
      # Fully revert our changes so an invalid config can't silently break sshd
      # on the next reboot: remove the drop-in (sshd_config.d path) AND restore
      # the pre-edit main config (fallback path). Leave the running sshd
      # untouched — we never restarted it on an invalid config.
      [ -n "${HARDENING_CONF:-}" ] && sudo rm -f "$HARDENING_CONF"
      [ -n "${SSHD_PREEDIT_BACKUP:-}" ] && sudo cp "$SSHD_PREEDIT_BACKUP" /etc/ssh/sshd_config
      echo "    [warn] sshd config failed validation — reverted our changes, SSH left unchanged. Review /etc/ssh manually."
    elif systemctl cat sshd.service &>/dev/null; then
      sudo systemctl restart sshd
    else
      sudo systemctl restart ssh
    fi
    [ -n "${SSHD_PREEDIT_BACKUP:-}" ] && rm -f "$SSHD_PREEDIT_BACKUP"
  fi
  set_step 5
fi

# ── 6. Firewall ─────────────────────────────────────────────────────────────
if ! run_step 6; then
  echo "==> [6/$TOTAL_STEPS] Configuring firewall..."
  case "$PKG_MGR" in
    apt)
      sudo ufw default deny incoming
      sudo ufw default allow outgoing
      # The OpenSSH app profile is hard-bound to port 22. If sshd was pre-configured
      # on a non-standard port, limiting only 22 under default-deny would lock the
      # user out. Read the effective port from `sshd -T` (read-only) and rate-limit
      # that; fall back to the OpenSSH profile when it's 22 or undeterminable.
      SSH_PORT="$(sudo sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
      if [ -n "${SSH_PORT:-}" ] && [ "$SSH_PORT" != "22" ]; then
        sudo ufw limit "${SSH_PORT}/tcp"
      else
        sudo ufw limit OpenSSH
      fi
      sudo ufw --force enable
      # Docker manages its own iptables rules; published container ports (-p)
      # insert into the FORWARD path AHEAD of UFW and bypass `default deny
      # incoming`, exposing them to the internet despite the firewall. Add a
      # deny-by-default DOCKER-USER chain so published ports aren't public
      # unless explicitly allowed. This touches ONLY the FORWARD-path
      # DOCKER-USER chain (never INPUT), so it cannot affect host SSH; it runs
      # AFTER `enable` and is non-fatal, so a reload failure leaves UFW up with
      # its base rules. Only meaningful once Docker is installed.
      if command -v docker &>/dev/null \
         && ! grep -q 'DOCKER-USER' /etc/ufw/after.rules 2>/dev/null; then
        sudo tee -a /etc/ufw/after.rules > /dev/null <<'DOCKERUFW'

# setup-vm: deny-by-default for Docker-published ports (DOCKER-USER runs in the
# FORWARD path before Docker's own ACCEPTs). Allow responses, per-port `ufw
# route` exceptions, and RFC1918/inter-container traffic; drop all other new
# inbound (the public internet).
# The jump to ufw-user-forward (created by before.rules, loaded first in the same
# iptables-restore) makes per-port re-allow work: after a new connection clears
# the established fast-path, it's offered to the user's ufw route rules; only if
# none match does it fall through to the RFC1918 returns and the final drop.
# Re-allow a specific published port with: ufw route allow proto tcp to any port <p>
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -j DROP
COMMIT
DOCKERUFW
        sudo ufw reload || echo "    [warn] ufw reload failed after adding DOCKER-USER rules — Docker ports may still be exposed; review /etc/ufw/after.rules."
      fi
      ;;
    dnf|yum)
      sudo systemctl enable --now firewalld
      # Order matters to avoid a lockout window: permanently allow ssh in the drop
      # zone, reload so it's live, THEN switch the default to drop. (Note:
      # --set-default-zone is a combined runtime+permanent op and rejects
      # --permanent; and --add-service must target --zone=drop, else it lands in
      # the old default zone and ssh is absent once drop becomes default.)
      sudo firewall-cmd --permanent --zone=drop --add-service=ssh
      # The `ssh` service is port 22 only. If sshd was pre-configured on a
      # non-standard port, also open that port in drop — otherwise switching the
      # default zone to drop locks the user out (mirrors the ufw branch above).
      FW_SSH_PORT="$(sudo sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
      if [ -n "${FW_SSH_PORT:-}" ] && [ "$FW_SSH_PORT" != "22" ]; then
        sudo firewall-cmd --permanent --zone=drop --add-port="${FW_SSH_PORT}/tcp"
      fi
      sudo firewall-cmd --reload
      sudo firewall-cmd --set-default-zone=drop
      # firewalld has no built-in SSH rate limiting — that's delegated to fail2ban.
      # If fail2ban isn't available (e.g. Amazon Linux 2023 has no EPEL), say so
      # plainly: this host will have no SSH brute-force throttling.
      if ! command -v fail2ban-server &>/dev/null; then
        echo "    [warn] fail2ban unavailable on this host — SSH brute-force throttling will not be active."
      fi
      ;;
  esac
  set_step 6
fi

# ── 7. fail2ban ─────────────────────────────────────────────────────────────
if ! run_step 7; then
  echo "==> [7/$TOTAL_STEPS] Configuring fail2ban..."
  if ! command -v fail2ban-server &>/dev/null; then
    echo "    [skip] fail2ban not installed (no EPEL on this distro?) — skipping"
    # Record the skip so the exit summary shows [skip], not a misleading [done].
    mark_skipped 7
    set_step 7
  else
    # Write a minimal jail.local with only our overrides. Copying the whole
    # jail.conf would permanently mask future package updates to it. Don't
    # clobber a pre-existing customized jail.local on re-run.
    if [ ! -f /etc/fail2ban/jail.local ]; then
      # Only override banaction on firewalld systems (ban via firewalld). Anywhere
      # else, omit it so fail2ban's distro-tuned default applies — hardcoding
      # iptables-multiport can fail on nftables-only hosts.
      F2B_BANACTION=""
      if [ "$PKG_MGR" != "apt" ] && command -v firewall-cmd &>/dev/null; then
        F2B_BANACTION="firewallcmd-ipset"
      fi
      {
        echo "[DEFAULT]"
        [ -n "$F2B_BANACTION" ] && echo "banaction = ${F2B_BANACTION}"
        echo ""
        echo "[sshd]"
        echo "enabled = true"
      } | sudo tee /etc/fail2ban/jail.local > /dev/null
    fi
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    set_step 7
  fi
fi

# ── 8. Passwordless sudo ────────────────────────────────────────────────────
if ! run_step 8; then
  echo "==> [8/$TOTAL_STEPS] Setting up passwordless sudo for ${USERNAME}..."
  # Validate the fragment with `visudo -cf` in a temp file before installing it
  # into sudoers.d — a malformed entry placed there can break sudo entirely.
  # install -m 0440 sets ownership/mode atomically (sudoers.d requires 0440).
  # Sanitize the FILENAME to [A-Za-z0-9_-]: sudo silently ignores sudoers.d files
  # whose names contain a '.', so a username like 'john.doe' would otherwise
  # produce a file that is parsed-as-valid-but-never-loaded (grant silently lost).
  # The file CONTENT keeps the real ${USERNAME} (dots are legal inside sudoers).
  SUDOERS_NAME="$(printf '%s' "$USERNAME" | tr -c 'A-Za-z0-9_-' '_')"
  SUDOERS_TMP="$(mktemp)"
  echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
  if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "/etc/sudoers.d/${SUDOERS_NAME}"
  else
    echo "    [warn] passwordless-sudo fragment failed visudo validation — skipping."
  fi
  rm -f "$SUDOERS_TMP"
  set_step 8
  reboot_if_needed
fi

# ── 9. Tailscale ────────────────────────────────────────────────────────────
if ! run_step 9; then
  echo "==> [9/$TOTAL_STEPS] Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  echo ""
  echo "    Tailscale will print a login URL below. Open it in a browser"
  echo "    on any device to authorize this machine. The script will"
  echo "    block here until you complete the login."
  echo ""
  sudo tailscale up --ssh --accept-routes
  # If UFW is active, allow Tailscale's tunnel interface through it so
  # direct peer connections work instead of falling back to DERP relays.
  if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    sudo ufw allow in on tailscale0 2>/dev/null || true
  fi
  # Tailscale network performance optimization (networkd-dispatcher is Debian/Ubuntu only)
  if [ "$PKG_MGR" = "apt" ]; then
    sudo mkdir -p /etc/networkd-dispatcher/routable.d
    sudo tee /etc/networkd-dispatcher/routable.d/50-tailscale > /dev/null <<'TSOPT'
#!/bin/sh
# Extract the egress interface by the token after "dev" rather than a fixed
# field number: a no-gateway route (Tailscale exit node, WireGuard, p2p link)
# omits the "via <gw>" tokens, which would shift a positional `cut` onto the
# src IP and run ethtool against an address instead of an interface name.
IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
[ -n "$IFACE" ] && ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
TSOPT
    sudo chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale
  else
    # On RPM distros, use a NetworkManager dispatcher script
    sudo mkdir -p /etc/NetworkManager/dispatcher.d
    sudo tee /etc/NetworkManager/dispatcher.d/50-tailscale > /dev/null <<'TSOPT'
#!/bin/sh
[ "$2" = "up" ] || exit 0
ethtool -K "$1" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
TSOPT
    sudo chmod 755 /etc/NetworkManager/dispatcher.d/50-tailscale
  fi
  set_step 9
fi

# ── 10. GitHub CLI ──────────────────────────────────────────────────────────
if ! run_step 10; then
  echo "==> [10/$TOTAL_STEPS] Installing GitHub CLI..."
  case "$PKG_MGR" in
    apt)
      # Fetch the keyring straight to its destination with sudo curl (no wget
      # dependency, no temp file to leak), matching the Docker keyring pattern.
      sudo mkdir -p -m 755 /etc/apt/keyrings
      sudo curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
      sudo chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
      GH_ARCH="$(dpkg --print-architecture)"
      echo "deb [arch=${GH_ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
      sudo apt update
      pkg_install gh
      ;;
    dnf|yum)
      add_rpm_repo https://cli.github.com/packages/rpm/gh-cli.repo
      pkg_install gh
      ;;
  esac
  set_step 10
fi

# ── 11. GitHub auth + Git config ────────────────────────────────────────────
if ! run_step 11; then
  echo "==> [11/$TOTAL_STEPS] Authenticating with GitHub..."
  if ! gh auth status &>/dev/null; then
    gh auth login
  else
    echo "    Already authenticated as $(gh api user --jq '.login')"
  fi
  git config --global init.defaultBranch main
  # Fetch all identity fields in ONE API call: four separate `gh api user` calls
  # each add a network failure point that would abort the run under set -e after
  # auth already succeeded. gh's built-in jq emits a TAB-separated row (no
  # external jq needed); IFS=$'\t' read keeps a display name with spaces intact.
  # .name falls back to .login so the identity is never the literal "null".
  IFS=$'\t' read -r GH_NAME GH_EMAIL GH_ID GH_LOGIN \
    < <(gh api user --jq '[.name // .login, .email // "", .id, .login] | @tsv')
  if [ -z "$GH_EMAIL" ]; then
    GH_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"
  fi
  git config --global user.name "$GH_NAME"
  git config --global user.email "$GH_EMAIL"
  echo "    Git identity: ${GH_NAME} <${GH_EMAIL}>"
  set_step 11
fi

# ── 12. Node.js LTS (via NodeSource repo) ────────────────────────────────────
if ! run_step 12; then
  echo "==> [12/$TOTAL_STEPS] Installing Node.js LTS..."
  case "$PKG_MGR" in
    apt)
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
      sudo apt update
      pkg_install nodejs
      ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
      pkg_install nodejs
      ;;
  esac
  set_step 12
fi

# ── 13. PATH setup ──────────────────────────────────────────────────────────
if ! step_done 13; then
  echo "==> [13/$TOTAL_STEPS] Configuring PATH..."
  # shellcheck disable=SC2016  # intentional: write the literal, unexpanded line
  if [ ! -f "$HOME/.bashrc" ] || ! grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  set_step 13
fi

# ── 14. Claude Code ─────────────────────────────────────────────────────────
if ! run_step 14; then
  echo "==> [14/$TOTAL_STEPS] Installing Claude Code (global)..."
  # The global install needs npm, which Node.js LTS (step 12) provides. Guard in
  # case that step was skipped or failed, so we don't error out on a missing npm.
  if ! command -v npm &>/dev/null; then
    echo "    [skip] npm not found — enable the Node.js LTS step to install Claude Code globally"
    # Record the skip so the exit summary shows [skip], not a misleading [done].
    mark_skipped 14
  else
    # Install globally via npm. Unlike the native installer, which only does a
    # per-user install under ~/.local/bin, this puts the `claude` binary in the
    # system-wide npm bin dir. @latest grabs the newest published release.
    sudo npm install -g @anthropic-ai/claude-code@latest

    # Make sure `claude` is on PATH. With the NodeSource Node the global bin is
    # /usr/bin (already on PATH); if npm's global prefix is elsewhere, add it for
    # this session and future logins.
    if ! command -v claude &>/dev/null; then
      # Query the prefix with `sudo` so it matches the `sudo npm install -g`
      # above — root's global prefix can differ from the unprivileged user's
      # (e.g. if the user has an NVM-managed prefix), and a bare `npm prefix -g`
      # would point at the wrong dir and miss the just-installed binary.
      NPM_GLOBAL_BIN="$(sudo npm prefix -g 2>/dev/null)/bin"
      if [ -x "$NPM_GLOBAL_BIN/claude" ]; then
        export PATH="$NPM_GLOBAL_BIN:$PATH"
        if [ -f "$HOME/.bashrc" ] && ! grep -qF "export PATH=\"$NPM_GLOBAL_BIN:\$PATH\"" "$HOME/.bashrc"; then
          echo "export PATH=\"$NPM_GLOBAL_BIN:\$PATH\"" >> "$HOME/.bashrc"
        fi
      fi
    fi
  fi
  set_step 14
fi

# ── 15. Claude Code authentication ────────────────────────────────────────
if ! step_done 15; then
  if command -v claude &>/dev/null; then
    echo "==> [15/$TOTAL_STEPS] Authenticating Claude Code..."
    echo ""
    echo "    To get a permanent API token, run this command in a"
    echo "    separate terminal (or open a new SSH session):"
    echo ""
    echo "      claude setup-token"
    echo ""
    echo "    Follow the prompts there — it will give you a token."
    echo "    Then paste it here when ready."
    echo ""
    # -s so the secret isn't echoed to the terminal / scrollback.
    read -rsp "    Paste your Claude API token: " CLAUDE_TOKEN
    echo ""
    if [ -n "$CLAUDE_TOKEN" ]; then
      mkdir -p "$HOME/.config/gabai"
      # Create under a tight umask so the file is never briefly world-readable.
      ( umask 077; printf '%s\n' "$CLAUDE_TOKEN" > "$HOME/.config/gabai/api-key" )
      chmod 600 "$HOME/.config/gabai/api-key"
      echo "    Token saved. /gabai-core:setup will use it when creating .env"
    else
      echo "    No token entered — you can set ANTHROPIC_API_KEY later during setup."
    fi
    # Drop the secret from the environment so it isn't exposed via /proc/PID/environ
    # for the rest of the run; the on-disk 0600 copy is the source of truth now.
    unset CLAUDE_TOKEN
  else
    echo "    [skip] Claude Code not installed — skipping authentication"
    mark_skipped 15
  fi
  set_step 15
fi

# ── 16. GabAI bootstrap ─────────────────────────────────────────────────
if ! step_done 16; then
  if command -v claude &>/dev/null; then
    echo "==> [16/$TOTAL_STEPS] Installing Claude Code plugins..."
    # Ensure the official marketplace is registered before installing from it.
    # Recent Claude Code ships it as a default, but add it explicitly so a fresh
    # install never depends on that auto-registration.
    claude plugin marketplace add anthropics/claude-plugins-official \
      || echo "    [warn] official marketplace add failed"
    # Don't let one failed plugin install block the others
    OFFICIAL_PLUGINS=(
      claude-code-setup
      claude-md-management
      context7
      firecrawl
      superpowers
      skill-creator
    )
    for plugin in "${OFFICIAL_PLUGINS[@]}"; do
      claude plugin install "${plugin}@claude-plugins-official" --scope user \
        || echo "    [warn] ${plugin} install failed"
    done

    # GabAI skills from the Chabad Commons marketplace
    claude plugin marketplace add chabad-commons/GabAIskills || echo "    [warn] GabAIskills marketplace add failed"
    claude plugin install gabai-core@gabai-skills --scope user || echo "    [warn] gabai-core install failed"
  else
    echo "    [skip] Claude Code not installed — skipping plugins"
    mark_skipped 16
  fi
  set_step 16
fi

# ── 17. Create code directory ───────────────────────────────────────────────
if ! step_done 17; then
  echo "==> [17/$TOTAL_STEPS] Creating ~/code..."
  mkdir -p "$HOME/code"
  set_step 17
fi

# ── 18. tmux configuration ──────────────────────────────────────────────────
if ! step_done 18; then
  echo "==> [18/$TOTAL_STEPS] Writing ~/.tmux.conf..."
  # Don't clobber a tmux config the user may have customized.
  if [ -f "$HOME/.tmux.conf" ]; then
    echo "    [skip] ~/.tmux.conf already exists — leaving it untouched."
  else
    cat > "$HOME/.tmux.conf" <<'TMUXCONF'
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g mouse on
set -g allow-passthrough on

# Eliminate escape key delay (important for responsive Claude Code UI)
set -s escape-time 0

# Let editors inside tmux detect focus (used by some Claude Code integrations)
set -g focus-events on

# Larger scrollback — Claude responses can be long
set -g history-limit 50000

# System clipboard integration
set -g set-clipboard on
TMUXCONF
  fi
  set_step 18
fi

# ═══════════════════════════════════════════════════════════════════════════
# DONE — clean up
# ═══════════════════════════════════════════════════════════════════════════
# Capture completion count and skip list before cleanup removes the state files,
# so the EXIT-trap summary reports the real total and still marks skipped steps.
COMPLETED_SNAPSHOT="$(get_step)"
SKIP_SNAPSHOT="$(cat "$SKIP_FILE" 2>/dev/null || true)"
remove_resume_hook
# Only self-delete if the script lives under the user's home or /tmp.
# Defends against `sudo bash setup-vm.sh` somehow resolving $0 to a system
# binary, which would turn `rm -f "$SCRIPT_PATH"` into a disaster.
case "$SCRIPT_PATH" in
  "$HOME"/*|/tmp/*|/var/tmp/*) rm -f "$SCRIPT_PATH" ;;
  *) echo "    (leaving $SCRIPT_PATH in place — not under \$HOME or /tmp)" ;;
esac

echo ""
echo "  Your server is ready!"
# Only steer the user to /gabai-core:setup when Claude Code is actually present
# — otherwise that command doesn't exist and the "ready" banner is misleading.
if command -v claude &>/dev/null; then
  echo "  Now open Claude Code and run:"
  echo ""
  echo "    /gabai-core:setup"
  echo ""
  echo "  This will set up your personal Shlichus AI assistant."
  echo "  (If any plugin install reported [warn] above, re-run that install first.)"
else
  echo "  Claude Code was not installed, so GabAI setup was skipped. To use it,"
  echo "  re-download this script and run it with Node.js LTS + Claude Code enabled."
fi
echo ""
echo "  (You may want to reboot first: sudo reboot)"

read -rp "Reboot now? [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  sudo reboot
fi
