#!/bin/bash
set -eo pipefail

# --- Pre-flight: refuse pure-root execution ---
# Running directly as root (login root / `su -` / cron) means $SUDO_USER is
# unset and the installer would write every pipx tool to /root/.local/bin
# and every Go binary to /root/go/bin — neither of which is on any normal
# user's PATH. The /etc/environment PATH this script configures targets
# $SUDO_USER's ~/.local/bin, so root-local installs become orphans that
# the user's shells (and PAM-spawned non-interactive sessions) can't see.
# Enforce the supported invocation: `sudo bash install-offsec-tools.sh …`
# from a regular account. CI / container scenarios can opt out by setting
# SUDO_USER=root explicitly before invoking the script.
if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
    cat >&2 <<EOF
ERROR: pure-root execution detected (\$SUDO_USER is unset).

Run the installer via sudo from your regular account instead:

    sudo bash $0 [--insecure] <install_dir>

Reason: invoking directly as root puts pipx tools in /root/.local/bin and
Go binaries in /root/go/bin, both invisible to any normal user's shell and
to the /etc/environment PATH this script writes. Re-running later as a
normal user produces duplicated toolchains and chowns \$INSTALL_DIR to
that user, leaving the root-side copies as orphans.

Escape hatch (only for headless/CI containers with no other user):
    SUDO_USER=root bash $0 [--insecure] <install_dir>
EOF
    exit 1
fi

# --- Configuration ---
INSTALL_DIR=""
GO_VERSION="1.26.3"

# Resolve the real invoking user (the one before sudo). Used to scope GOBIN /
# pipx installs to their $HOME instead of /root, so binaries land where the
# user's PATH (and /etc/environment) already point. Must be resolved BEFORE
# GOBIN so the toolchain installs end up in a path the user actually has.
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

export GOROOT="/usr/local/go"
# Pin GOBIN to the invoking user's home — not $HOME, which under sudo is /root.
# Without this, `go install` would drop binaries into /root/go/bin where the
# real user never sees them, forcing a sync step into /usr/local/bin. With
# GOBIN under the user's home and the user's home on every PATH surface
# (/etc/environment, image ENV, ~/.bashrc), no sync is needed.
export GOBIN="$TARGET_HOME/go/bin"
# Prepend /usr/local/go/bin so the freshly-installed toolchain wins over any
# system `go` (apt's golang-go) that might be earlier in PATH. Also expose the
# user's .local/bin so post-install checks (e.g. `command -v search_vulns`)
# resolve when invoked from root's PATH.
export PATH="$GOROOT/bin:$GOBIN:$TARGET_HOME/.local/bin:$PATH"
# Pin the toolchain: never let `go` silently download a newer version from
# proxy.golang.org mid-install (fails behind MITM TLS, and hides version drift).
export GOTOOLCHAIN=local

# Run a command as the original invoking user, with their $HOME and the
# insecure-mode env vars (PIP_TRUSTED_HOST, GIT_SSL_NO_VERIFY) forwarded
# explicitly. Required because sudo strips HOME by default, which makes
# pipx install everything under /root and orphan it from the user's PATH.
as_user() {
    sudo -u "$TARGET_USER" -H \
        PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-}" \
        GIT_SSL_NO_VERIFY="${GIT_SSL_NO_VERIFY:-}" \
        PATH="$TARGET_HOME/.local/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$@"
}

# --- Help Menu ---
usage() {
    cat <<EOF
Usage: $0 [-k|--insecure] <install_dir>

Positional:
  <install_dir>      Where to clone source repos / extract bundles (e.g. /opt)

Options:
  -n, --dry-run      Print the install_* functions that would run for the
                     selected --groups, then exit 0 without performing any
                     installation. Used by the test suite.
  --groups=g1,g2,..  Install only the listed groups (comma-separated).
                     Omit to install everything. Pass --groups=none to skip
                     installation entirely (no-op; exits 0 without touching
                     the system). Valid groups: base, PD, praetorian,
                     tomnomnom, recon, takeover, dictionary, sast, dast,
                     cracking, RT, cloud, reversing, utils, AI.
                     (The Go toolchain is now installed unconditionally by
                     'base' — every downstream group that uses `go install`
                     depends on it, so it is no longer a selectable group.)
  -k, --insecure     Disable TLS certificate verification for curl, wget, git,
                     go module fetches, pip/pipx, and apt HTTPS sources. Use
                     ONLY behind a trusted MITM proxy (e.g. corporate egress
                     filter) where you cannot install the intercepting CA into
                     the system trust store. APT package integrity is still
                     enforced via GPG signatures regardless of this flag.

Examples:
  $0 /opt
  $0 --insecure /opt
EOF
    exit 1
}

INSECURE=0
DRY_RUN=0
REQUESTED_GROUPS=""
GROUPS_PROVIDED=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -k|--insecure)    INSECURE=1; shift ;;
        -n|--dry-run)     DRY_RUN=1; shift ;;
        --groups=*)       REQUESTED_GROUPS="${1#--groups=}"; GROUPS_PROVIDED=1; shift ;;
        -h|--help)        usage ;;
        --)            shift; break ;;
        -*)            echo "ERROR: unknown flag: $1"; usage ;;
        *)
            if [ -z "$INSTALL_DIR" ]; then
                INSTALL_DIR="$1"; shift
            else
                echo "ERROR: too many positional arguments"; usage
            fi
            ;;
    esac
done

# --groups=none: explicit scaffold-only / no-op path. Exits before any
# validation, insecure-mode toggles, apt update, or install_* invocation.
# Used by callers (newPT.sh, container builds) that want the calling-convention
# without the toolchain — no INSTALL_DIR required in this mode.
if [ "$REQUESTED_GROUPS" = "none" ]; then
    echo "[+] --groups=none — skipping installation."
    exit 0
fi

if [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: INSTALL_DIR is required."
    usage
fi

# --- Insecure-mode toggles ---
# When enabled, every TLS-using tool below skips peer/host verification.
# Variables are expanded into command lines (empty string = no-op when secure).
CURL_INSECURE=""
WGET_INSECURE=""
INSECURE_APT_CONF=""
if [ "$INSECURE" -eq 1 ]; then
    cat >&2 <<'EOF'
[!] ============================================================
[!] INSECURE MODE: TLS certificate verification is DISABLED for:
[!]   curl, wget, git, go (modules + sumdb), pip/pipx, apt HTTPS
[!] Only safe behind a trusted MITM proxy. APT GPG signatures
[!] still validate package integrity.
[!] ============================================================
EOF
    CURL_INSECURE="-k"
    WGET_INSECURE="--no-check-certificate"
    export GIT_SSL_NO_VERIFY=true
    export GOINSECURE='*'
    export GOSUMDB=off
    export GOPROXY=direct
    export PIP_TRUSTED_HOST="pypi.org files.pythonhosted.org github.com objects.githubusercontent.com raw.githubusercontent.com"

    # apt over HTTPS: disable TLS verify via drop-in conf. Removed on exit.
    INSECURE_APT_CONF="/etc/apt/apt.conf.d/99-insecure-tls"
    sudo tee "$INSECURE_APT_CONF" >/dev/null <<'APT_EOF'
Acquire::https::Verify-Peer "false";
Acquire::https::Verify-Host "false";
APT_EOF
    trap 'sudo rm -f "$INSECURE_APT_CONF" 2>/dev/null || true' EXIT
fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[+] Creating install directory $INSTALL_DIR"
    if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
        sudo mkdir -p "$INSTALL_DIR" \
            || { echo "ERROR: Unable to create directory $INSTALL_DIR"; exit 1; }
    fi
fi

# Normalize path to absolute
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

# Refuse destructive install dirs
case "$INSTALL_DIR" in
    /|/bin|/sbin|/lib|/lib64|/usr|/etc|/boot|/dev|/proc|/sys|/root|/home)
        echo "ERROR: refusing to install into $INSTALL_DIR"
        exit 1
        ;;
esac

# Make INSTALL_DIR writable by the current user so subsequent clones don't need sudo
if [ ! -w "$INSTALL_DIR" ]; then
    echo "[+] Granting ownership of $INSTALL_DIR to current user"
    sudo chown -R "$(id -u):$(id -g)" "$INSTALL_DIR"
fi

mkdir -p "$GOBIN"

# --- Helpers ---

# retry <max> <delay> <cmd...> : re-run a flaky command up to <max> times,
# sleeping <delay>s between attempts; returns the command's last exit status.
# Module fetches through proxy.golang.org / storage.googleapis.com occasionally
# drop mid-build on a transient network blip (and in an IPv6-less container Go's
# dialer surfaces it as "cannot assign requested address" on the AAAA it always
# tries first). A multi-minute install shouldn't die on one dropped connection.
retry() {
    local max="$1" delay="$2"; shift 2
    local n=1 rc=0
    until "$@"; do
        rc=$?
        if [ "$n" -ge "$max" ]; then
            echo "[!] '$*' failed after $max attempts (rc=$rc)" >&2
            return "$rc"
        fi
        echo "[retry $n/$max] '$*' failed (rc=$rc); sleeping ${delay}s..." >&2
        sleep "$delay"
        n=$((n + 1))
    done
}

# go_install : drop-in for `go install` with retry. Go reuses its module cache
# across attempts, so a retry resumes rather than re-downloading everything.
go_install() {
    retry 3 10 go install "$@"
}

clone_if_missing() {
    # Usage: clone_if_missing <url> <dest> [extra git args...]
    local url="$1"
    local dest="$2"
    shift 2
    if [ -d "$dest/.git" ]; then
        echo "[=] $dest already present, skipping clone"
        return 0
    fi
    git clone "$@" "$url" "$dest"
}

detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Returns the ID_LIKE chain from /etc/os-release (e.g. "debian" for Kali/Parrot/Mint).
# Empty string if not set (genuine Debian/Ubuntu omit ID_LIKE).
detect_distro_family() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID_LIKE:-}"
    else
        echo ""
    fi
}

# True only for distros where Docker publishes its official apt repo.
# Docker's signed repos exist for `debian` and `ubuntu` exclusively — every
# derivative (Kali, Parrot, Mint, Pop!_OS, ...) must use the distro's own
# docker.io package because Docker's repo has no matching codename for them.
is_docker_official_supported() {
    case "$(detect_distro)" in
        debian|ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

# Write the toolchain PATH to /etc/environment so PAM exposes it to every SSH
# session — including non-interactive `ssh host cmd` invocations used by n8n,
# cron, etc. (those shells never source ~/.bashrc or /etc/profile).
# /etc/environment is plain KEY=VALUE with no shell expansion, so $HOME must be
# resolved to a literal path here.
configure_system_path() {
    echo "[+] Updating /etc/environment so non-interactive SSH shells see the tool PATH..."

    # Resolve the real target user even when running under sudo (where $HOME=/root)
    local target_user target_home
    target_user="${SUDO_USER:-$USER}"
    target_home="$(getent passwd "$target_user" | cut -d: -f6)"
    [ -n "$target_home" ] || target_home="$HOME"

    local new_path
    # Order: Go toolchain → user's GOBIN (where `go install` drops binaries) →
    # user's pipx/.local/bin → system paths. Everything tool-related lives in
    # one of these; no sync_go_bins step needed.
    new_path="/usr/local/go/bin:${target_home}/go/bin:${target_home}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # One-time backup so a bad PATH can be recovered
    if [ ! -f /etc/environment.bak ]; then
        sudo cp -a /etc/environment /etc/environment.bak 2>/dev/null || true
    fi

    # Atomic rewrite: drop any existing PATH= line, append the new one,
    # then install back with root ownership and sane perms.
    local tmp
    tmp="$(mktemp)"
    grep -v '^[[:space:]]*PATH=' /etc/environment 2>/dev/null > "$tmp" || true
    echo "PATH=\"${new_path}\"" >> "$tmp"
    sudo install -m 0644 -o root -g root "$tmp" /etc/environment
    rm -f "$tmp"

    echo "[=] /etc/environment PATH set for user '${target_user}' (home: ${target_home})"
    echo "    New SSH sessions (including n8n's SSH node) will pick this up automatically."
}

# --- Go toolchain ---
#
# Not a selectable group: install_base calls install_go unconditionally,
# because every downstream group that uses `go install` (PD, tomnomnom,
# recon, takeover, utils, AI, ...) requires the toolchain on PATH. Keeping
# Go optional led to silent breakage on profiles like `lite` / `mobile`
# that omitted it.
install_go() {
    echo "[+] Installing Go ${GO_VERSION}..."

    # Pin Go's resolver to libc (which honours the /etc/gai.conf IPv4 precedence
    # rule that install_base drops in). Without this, Go's pure-Go resolver may
    # still pick IPv6 first and fail with "cannot assign requested address".
    export GODEBUG="${GODEBUG:+${GODEBUG},}netdns=cgo"

    if command -v go >/dev/null 2>&1 && go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
        echo "[=] Go ${GO_VERSION} already installed"
        return 0
    fi
    local arch tarball
    case "$(uname -m)" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "ERROR: unsupported arch $(uname -m)"; return 1 ;;
    esac
    tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
    curl $CURL_INSECURE -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"
    hash -r
}

# --- Tool Modules ---

install_base() {
    echo "[+] Installing Base Utilities..."

    # Default Docker bridge networks lack a routable IPv6 source, but the
    # public mirrors we hit (deb.debian.org, proxy.golang.org, ...) advertise
    # AAAA records. The resolver picks an IPv6, connect() fails synchronously
    # ("cannot assign requested address" for Go, half-fetched InRelease →
    # "NOSPLIT" for apt). Pin getaddrinfo to prefer IPv4 globally — no-op on
    # hosts where IPv6 actually works.
    if [ ! -f /etc/gai.conf ] || ! grep -q '::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" | sudo tee -a /etc/gai.conf >/dev/null
    fi

    sudo apt update
    sudo apt install -y \
        git curl wget jq zip unzip ncat openssh-client sshpass tmux pipx python3-pip bat gnupg \
        sqlite3 gcc make libpcap-dev chromium asciinema ripgrep ca-certificates xxd \
        redis-tools ruby ruby-dev nodejs npm

    install_docker
    install_go

    sudo apt install -y locate snmp ldap-utils tcpdump net-tools \
        iputils-ping iputils-tracepath iproute2 dnsutils traceroute mtr-tiny whois telnet
    # snmp-mibs-downloader lives in non-free (proprietary MIB licenses) — present
    # on pentest hosts (Kali/Parrot), absent on slim Debian/Ubuntu images that
    # only enable `main`. It's a convenience (translates OIDs to symbolic names);
    # without it snmpwalk just prints numeric OIDs. Skip on failure rather than
    # killing the whole install for downstream containers.
    sudo apt install -y snmp-mibs-downloader 2>/dev/null \
        || echo "[!] snmp-mibs-downloader unavailable (non-free not enabled?) — skipping"

    # Claude Code — Anthropic's CLI. Lives in install_base (not install_AI)
    # because every engagement container assumes `claude` is on PATH regardless
    # of which AI assistant groups the operator picked.
    if command -v claude >/dev/null 2>&1; then
        echo "[=] claude already installed: $(claude --version 2>/dev/null) — skipping"
    else
        sudo npm install -g @anthropic-ai/claude-code
    fi

    as_user pipx ensurepath

    # uv — Astral's fast Python toolchain manager. Lives alongside pipx as the
    # escape hatch for the rare tool that needs a Python version different
    # from the system's (`uv tool install --python 3.10 X` ships a standalone
    # Python alongside the venv). Day-to-day tooling stays on pipx for stability;
    # uv is here so future engagement-specific Python pin requirements don't
    # require bumping the whole base image.
    if [ -x "$TARGET_HOME/.local/bin/uv" ]; then
        echo "[=] uv already installed: $(as_user "$TARGET_HOME/.local/bin/uv" --version 2>/dev/null) — skipping"
    else
        echo "[+] Installing uv (Astral)..."
        # UV_NO_MODIFY_PATH=1: /etc/environment + Dockerfile ENV PATH already
        # cover ~/.local/bin, don't append duplicate exports to ~/.zshrc.
        as_user env UV_NO_MODIFY_PATH=1 bash -c \
            "curl $CURL_INSECURE -LsSf https://astral.sh/uv/install.sh | sh"
    fi
}

# Install Docker Engine in a distro-portable, non-destructive way:
#   1. If `docker` is already on PATH, do nothing.
#   2. If a Docker apt source is already configured, reuse it (don't rewrite).
#   3. On genuine Debian/Ubuntu (and only there), add Docker's official apt repo.
#   4. On every other distro — including Debian/Ubuntu derivatives such as Kali,
#      Parrot, Mint, Pop!_OS, where Docker does NOT publish a matching codename —
#      install the distro-shipped `docker.io` package instead of pointing
#      sources.list.d at Docker's Debian repo (which would 404 on apt update).
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "[=] docker already installed: $(docker --version 2>/dev/null) — skipping repo setup"
        return 0
    fi

    local distro docker_list
    distro="$(detect_distro)"
    docker_list="/etc/apt/sources.list.d/docker.list"

    # Honor any pre-existing Docker apt source instead of clobbering it.
    if [ -f "$docker_list" ] && grep -q 'download\.docker\.com' "$docker_list"; then
        echo "[=] Docker apt source already configured at $docker_list — leaving as-is"
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        return 0
    fi

    if is_docker_official_supported; then
        local codename arch docker_repo_base
        docker_repo_base="https://download.docker.com/linux/${distro}"
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        arch="$(dpkg --print-architecture)"

        sudo install -m 0755 -d /etc/apt/keyrings
        if [ ! -s /etc/apt/keyrings/docker.asc ]; then
            sudo curl $CURL_INSECURE -fsSL "${docker_repo_base}/gpg" \
                -o /etc/apt/keyrings/docker.asc
            sudo chmod a+r /etc/apt/keyrings/docker.asc
        fi

        echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] ${docker_repo_base} ${codename} stable" \
            | sudo tee "$docker_list" > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        return 0
    fi

    # Derivative distro: prefer their docker.io package over forcing Debian's repo.
    echo "[!] Distro '$distro' has no matching Docker official repo — falling back to distro package"
    if sudo apt install -y docker.io docker-compose-plugin 2>/dev/null \
        || sudo apt install -y docker.io docker-compose 2>/dev/null \
        || sudo apt install -y docker.io; then
        echo "[=] Installed docker.io from $distro repos"
    else
        echo "[!] Could not install docker via apt on '$distro' — skipping Docker setup"
        echo "[!] Install Docker manually if you need container-based tooling later"
    fi
}

install_PD(){
    echo "[+] Installing Project Discovery Tools..."
    go_install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
    go_install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest
    go_install -v github.com/projectdiscovery/tlsx/cmd/tlsx@latest
    go_install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
    go_install -v github.com/projectdiscovery/katana/cmd/katana@latest
    go_install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest
    go_install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
    go_install -v github.com/projectdiscovery/interactsh/cmd/interactsh-client@latest

    clone_if_missing https://github.com/blechschmidt/massdns "$INSTALL_DIR/massdns"
    make -C "$INSTALL_DIR/massdns"
    sudo ln -sf "$INSTALL_DIR/massdns/bin/massdns" /usr/local/bin/massdns

    clone_if_missing https://github.com/trickest/resolvers "$INSTALL_DIR/resolvers"

    go_install -v github.com/projectdiscovery/mapcidr/cmd/mapcidr@latest
    go_install -v github.com/projectdiscovery/shuffledns/cmd/shuffledns@latest
    go_install -v github.com/projectdiscovery/alterx/cmd/alterx@latest
    go_install -v github.com/projectdiscovery/uncover/cmd/uncover@latest
    go_install -v github.com/projectdiscovery/urlfinder/cmd/urlfinder@latest
}

install_praetorian(){
    echo "[+] Installing Praetorian Tools..."
    go_install github.com/praetorian-inc/fingerprintx/cmd/fingerprintx@latest
    go_install github.com/praetorian-inc/nerva/cmd/nerva@latest
    go_install github.com/praetorian-inc/julius/cmd/julius@latest
    go_install github.com/praetorian-inc/brutus/cmd/brutus@latest
    go_install github.com/praetorian-inc/augustus/cmd/augustus@latest
    go_install github.com/praetorian-inc/titus/cmd/titus@latest
}

install_tomnomnom(){
    echo "[+] Installing Tomnomnom's Tools..."
    go_install -v github.com/tomnomnom/unfurl@latest
    go_install -v github.com/tomnomnom/assetfinder@latest
    go_install -v github.com/tomnomnom/anew@latest
    go_install -v github.com/tomnomnom/qsreplace@latest
    go_install -v github.com/tomnomnom/hacks/tok@latest
    go_install -v github.com/tomnomnom/hacks/html-tool@latest
    go_install -v github.com/tomnomnom/httprobe@latest
    go_install -v github.com/tomnomnom/gron@latest
    go_install -v github.com/tomnomnom/gf@latest
    go_install -v github.com/tomnomnom/comb@latest
}

install_takeover() {
    echo "[+] Installing Subdomain Takeover Tools..."
    go_install -v github.com/haccer/subjack@latest
}

install_cracking() {
    echo "[+] Installing Password Tools..."
    sudo apt install -y hashcat john hydra medusa hashid
}

install_dictionary(){
    echo "[+] Installing Custom Wordlist Tools..."
    sudo apt install -y cewl
    clone_if_missing https://github.com/t3l3machus/undust.py "$INSTALL_DIR/undust.py"
    go_install -v github.com/musana/fuzzuli@latest
    go_install -v github.com/s0md3v/wl/cmd/wl@latest
    go_install -v github.com/ImAyrix/fallparams@latest

    echo "[+] Installing wordlists..."
    echo "[*] Downloading SecLists (this may take a while)..."
    clone_if_missing https://github.com/danielmiessler/SecLists.git "$INSTALL_DIR/SecLists" --depth 1

    local rockyou_tar="$INSTALL_DIR/SecLists/Passwords/Leaked-Databases/rockyou.txt.tar.gz"
    local rockyou_txt="$INSTALL_DIR/SecLists/Passwords/Leaked-Databases/rockyou.txt"
    if [ -f "$rockyou_tar" ] && [ ! -f "$rockyou_txt" ]; then
        echo "[*] Extracting RockYou (this may take a while)..."
        tar -xvf "$rockyou_tar" -C "$INSTALL_DIR/SecLists/Passwords/Leaked-Databases/"
    fi
}

install_sast() {
    echo "[+] Installing SAST Tools..."
    sudo apt install -y cloc ripgrep zstd
    as_user pipx install semgrep
    go_install -v github.com/BishopFox/jsluice/cmd/jsluice@latest

    # Secret-scanning fleet — ptflow's content_discovery runs these ∥ over the downloaded response
    # corpus, then merges/dedups the hits: jsluice (above, JS AST) + gitleaks (regex, ANY file, so it
    # catches secrets in HTML/inline scripts jsluice's .js-only view misses) + trufflehog
    # (provider-verified, near-zero FP) + detect-secrets (entropy). The two Go tools land in $GOBIN
    # (~/go/bin); detect-secrets is a pipx CLI (~/.local/bin) like the other Python tools.
    go_install -v github.com/gitleaks/gitleaks/v8@latest
    go_install -v github.com/trufflesecurity/trufflehog/v3@latest
    as_user pipx install detect-secrets

    clone_if_missing https://github.com/semgrep/semgrep-rules "$INSTALL_DIR/semgrep-rules"

    if [ ! -d "$INSTALL_DIR/codeql" ]; then
        local codeql_tarball="$INSTALL_DIR/codeql-bundle-linux64.tar.zst"
        wget $WGET_INSECURE -O "$codeql_tarball" \
            https://github.com/github/codeql-action/releases/download/codeql-bundle-v2.24.2/codeql-bundle-linux64.tar.zst
        tar -I zstd -xf "$codeql_tarball" -C "$INSTALL_DIR/"
        rm -f "$codeql_tarball"
    fi
}

install_dast() {
    echo "[+] Installing Fuzzing Tools..."
    sudo apt install -y ffuf unzip dnsrecon 

    clone_if_missing https://github.com/sqlmapproject/sqlmap.git "$INSTALL_DIR/sqlmap-dev" --depth 1

    local tmp_ferox
    tmp_ferox="$(mktemp -d)"
    (
        cd "$tmp_ferox"
        curl $CURL_INSECURE -sLO https://github.com/epi052/feroxbuster/releases/latest/download/feroxbuster_amd64.deb.zip
        unzip -o feroxbuster_amd64.deb.zip
        sudo apt install -y ./feroxbuster_*_amd64.deb
    )
    rm -rf "$tmp_ferox"

    # HExHTTP (HTTP header/response anomaly scanner). pyproject.toml exposes a
    # `hexhttp` console script, so pipx installs it straight from git — no docker
    # image, which couldn't be built here anyway (this script runs inside the
    # devcontainer image build, where there's no docker daemon to talk to).
    as_user pipx install git+https://github.com/c0dejump/HExHTTP.git

    as_user pipx install wapiti3

    # shortscan + shortutil (IIS/ASP.NET 8.3 short-name enumeration — ptflow tech_enum). shortutil
    # builds the rainbow table shortscan resolves leaked 8.3 names against, so ptflow needs BOTH
    # (same repo, sibling cmd/); installing only shortscan leaves the enum half-wired.
    go_install -v github.com/bitquark/shortscan/cmd/shortscan@latest
    go_install -v github.com/bitquark/shortscan/cmd/shortutil@latest

    # dalfox (XSS) — ptflow's dedicated scanner over the request catalog's raw requests, run ∥ sqlmap.
    go_install -v github.com/hahwul/dalfox/v2@latest

    # Hidden-parameter discovery fleet (ptflow param_fuzz, PHASE 4): arjun (pipx → ~/.local/bin) ∥ x8.
    # x8 has no recent crates.io build the distro cargo can compile, so ptflow expects the PREBUILT
    # release binary in ~/.cargo/bin — drop the gzipped asset there directly (no Rust toolchain needed).
    as_user pipx install arjun

    local x8_dir="$TARGET_HOME/.cargo/bin"
    if [ ! -x "$x8_dir/x8" ]; then
        echo "[+] Installing x8 (Sh1Yo, prebuilt — distro cargo too old to compile)..."
        as_user mkdir -p "$x8_dir"
        local tmp_x8
        tmp_x8="$(mktemp -d)"
        curl $CURL_INSECURE -sSL \
            https://github.com/Sh1Yo/x8/releases/latest/download/x86_64-linux-x8.gz \
            -o "$tmp_x8/x8.gz"
        gunzip "$tmp_x8/x8.gz"
        install -m 0755 "$tmp_x8/x8" "$x8_dir/x8"
        chown "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$x8_dir/x8"
        rm -rf "$tmp_x8"
    else
        echo "[=] x8 already installed at $x8_dir/x8 — skipping"
    fi
}

install_recon() {
    echo "[+] Installing Port Scanning Tools..."
    sudo apt install -y nmap onesixtyone
    as_user pipx install git+https://github.com/Tib3rius/AutoRecon.git
    go_install -v github.com/pry0cc/tew@latest

    clone_if_missing https://github.com/robertdavidgraham/masscan "$INSTALL_DIR/masscan"
    make -C "$INSTALL_DIR/masscan"
    sudo make -C "$INSTALL_DIR/masscan" install

    echo "[+] Installing recon tools..."
    go_install -v github.com/lc/gau/v2/cmd/gau@latest
    # crawley (s0rg) — fast unix-way web crawler; alternative/complement to katana
    # for endpoint discovery, emits one URL per line for piping into the pipeline.
    go_install -v github.com/s0rg/crawley/cmd/crawley@latest
    go_install -v github.com/Chocapikk/wpprobe@latest
    wpprobe update-db

    # wpscan — WordPress vulnerability scanner. Ruby gem (ruby + ruby-dev
    # already in install_base); more thorough than wpprobe (integrates WPVulnDB).
    sudo gem install --no-document wpscan

    # search_vulns (ra1nb0rn) — local CVE lookup by product/version/CPE.
    # Install from git master, NOT the PyPI release: the released wheel lags the
    # prebuilt DB schema, so `-u` then leaves an INCOMPLETE DB and queries fail
    # with "no such table: ...". Uninstall first (pipx's uv backend refuses to
    # replace a venv it did not create this session, so `--force` alone errors on
    # a stale prior install). `-u` pulls the prebuilt vuln DB from the project's
    # GitHub releases, analogous to `wpprobe update-db`. All run via as_user so the
    # venv and DB land under $TARGET_USER's home, visible through /etc/environment.
    as_user pipx uninstall search-vulns >/dev/null 2>&1 || true
    as_user pipx install "git+https://github.com/ra1nb0rn/search_vulns.git"
    as_user search_vulns -u || echo "[!] search_vulns -u failed (DB sync skipped — re-run later)"

    # searchsploit (Exploit-DB CLI) — local exploit lookup, same workflow
    # phase as search_vulns and wpprobe (read-only DB grep, not active RT).
    clone_if_missing https://gitlab.com/exploit-database/exploitdb.git "$INSTALL_DIR/exploitdb"
    sudo ln -sf "$INSTALL_DIR/exploitdb/searchsploit" /usr/local/bin/searchsploit

    # EyeWitness (OPTIONAL — web screenshots + default-cred signatures for ptflow's screenshot step).
    # Not a PATH binary but a Selenium app: ptflow resolves it as <dir>/.venv/bin/python
    # <dir>/Python/EyeWitness.py with <dir> hardcoded to /opt/EyeWitness, so clone under $INSTALL_DIR
    # (= /opt in the standard layout, same as sqlmap-dev) and give it a self-contained venv. Chromium
    # comes from install_base; selenium >=4.45 lets Selenium Manager auto-provision chromedriver
    # headless (no Xvfb/sudo). Best-effort: a venv/pip failure must not abort the whole toolkit install.
    clone_if_missing https://github.com/RedSiege/EyeWitness "$INSTALL_DIR/EyeWitness"
    if [ ! -d "$INSTALL_DIR/EyeWitness/.venv" ]; then
        python3 -m venv "$INSTALL_DIR/EyeWitness/.venv" \
            && "$INSTALL_DIR/EyeWitness/.venv/bin/pip" install --upgrade pip selenium \
            || echo "[!] EyeWitness venv/selenium setup failed — ptflow screenshot step will skip it"
    fi
}

install_RT(){
    echo "[+] Installing Red Teaming Tools..."
    as_user pipx ensurepath
    as_user pipx install git+https://github.com/Pennyw0rth/NetExec
    as_user pipx install impacket

    # Rapid7's msfinstall is NOT idempotent: on re-runs it prompts
    # interactively to overwrite /usr/share/keyrings/metasploit-framework.gpg,
    # which deadlocks unattended/CI runs. Skip the whole step when msfconsole
    # is already on PATH.
    if command -v msfconsole >/dev/null 2>&1; then
        echo "[=] metasploit-framework already installed — skipping msfinstall"
    else
        local msf_installer="$INSTALL_DIR/msfinstall"
        curl $CURL_INSECURE -fsSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb \
            -o "$msf_installer"
        chmod 755 "$msf_installer"
        sudo "$msf_installer"
    fi
    apt update && sudo apt install -y metasploit-framework

    # Responder + mitm6: source clones kept under $INSTALL_DIR for inspection
    # and config tweaks (Responder.conf etc.), but runtime install goes through
    # pipx so deps land in isolated venvs instead of polluting the system Python
    # via --break-system-packages. Upstreams expose project metadata that pipx
    # consumes directly:
    #   lgandx/Responder  → pyproject.toml, exposes binary `responder`
    #   dirkjanm/mitm6    → setup.py,       exposes binary `mitm6`
    clone_if_missing https://github.com/lgandx/Responder "$INSTALL_DIR/Responder"
    as_user pipx install git+https://github.com/lgandx/Responder

    clone_if_missing https://github.com/dirkjanm/mitm6 "$INSTALL_DIR/mitm6"
    as_user pipx install git+https://github.com/dirkjanm/mitm6

    # AD / Kerberos toolkit
    go_install -v github.com/ropnop/kerbrute@latest
    as_user pipx install certipy-ad
    # evil-winrm — Ruby gem (ruby + ruby-dev already in install_base)
    sudo gem install --no-document evil-winrm

    sudo apt install -y proxychains4 smbmap smbclient nfs-common sshuttle

    # Tunneling / OOB infra — expose local listeners through NAT for callback
    # capture, webhook/OOB testing, and payload hosting during engagements.
    # Both ship as single static binaries; drop them straight into
    # /usr/local/bin rather than adding an apt repo, so the install stays
    # distro-portable (Kali/Parrot/derivatives) and honours --insecure.
    local tun_arch
    case "$(uname -m)" in
        x86_64)        tun_arch="amd64" ;;
        aarch64|arm64) tun_arch="arm64" ;;
        *) tun_arch=""; echo "[!] unsupported arch $(uname -m) — skipping ngrok/cloudflared" ;;
    esac

    if [ -n "$tun_arch" ]; then
        # cloudflared — Cloudflare Tunnel. Releases publish a raw per-arch binary.
        if command -v cloudflared >/dev/null 2>&1; then
            echo "[=] cloudflared already installed: $(cloudflared --version 2>/dev/null) — skipping"
        else
            echo "[+] Installing cloudflared (Cloudflare Tunnel)..."
            local tmp_cf
            tmp_cf="$(mktemp)"
            curl $CURL_INSECURE -fsSL \
                "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${tun_arch}" \
                -o "$tmp_cf"
            sudo install -m 0755 "$tmp_cf" /usr/local/bin/cloudflared
            rm -f "$tmp_cf"
        fi

        # ngrok — reverse tunnels. Stable v3 ships as a .tgz containing one binary.
        if command -v ngrok >/dev/null 2>&1; then
            echo "[=] ngrok already installed: $(ngrok --version 2>/dev/null) — skipping"
        else
            echo "[+] Installing ngrok..."
            local tmp_ngrok
            tmp_ngrok="$(mktemp -d)"
            curl $CURL_INSECURE -fsSL \
                "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${tun_arch}.tgz" \
                -o "$tmp_ngrok/ngrok.tgz"
            tar -xzf "$tmp_ngrok/ngrok.tgz" -C "$tmp_ngrok"
            sudo install -m 0755 "$tmp_ngrok/ngrok" /usr/local/bin/ngrok
            rm -rf "$tmp_ngrok"
        fi
    fi
}

install_cloud() {
    echo "[+] Installing Cloud Pentest Tools..."
    as_user pipx install awscli
    as_user pipx install pacu
    as_user pipx install prowler
    as_user pipx install scoutsuite
    go_install -v github.com/BishopFox/cloudfox@latest
}

install_reversing() {
    echo "[+] Installing Reverse Engineering Tools..."
    sudo apt install -y binwalk apktool jadx
    as_user pipx install frida-tools
}

install_utils() {
    echo "[+] Installing CLI Utilities..."
    go_install -v github.com/charmbracelet/glow@latest
}

install_AI() {
    echo "[+] Installing AI Coding & Pentesting Assistants..."

    # nodejs+npm normally come from install_base; defensive re-install for the
    # edge case where someone calls --groups=AI without base. Claude Code is
    # also installed by install_base — only Codex / sgpt / Strix live here.
    sudo apt install -y nodejs npm

    # Codex — OpenAI's coding CLI (distributed via npm).
    if command -v codex >/dev/null 2>&1; then
        echo "[=] codex already installed — skipping"
    else
        sudo npm install -g @openai/codex
    fi

    # sgpt — ChatGPT in the terminal (https://github.com/tbckr/sgpt).
    go_install -v github.com/tbckr/sgpt/v2/cmd/sgpt@latest

    # Strix — autonomous AI pentest agent (https://github.com/usestrix/strix).
    as_user pipx install strix-agent
}

# --- Main Execution Logic ---

# Canonical install order. Modify here, not in the filtering logic below,
# so dry-run output and actual execution stay in lockstep.
declare -a INSTALL_FNS_ALL=(
    install_base
    install_PD
    install_praetorian
    install_tomnomnom
    install_takeover
    install_recon
    install_cracking
    install_dictionary
    install_sast
    install_dast
    install_RT
    install_cloud
    install_reversing
    install_utils
    install_AI
)

declare -a INSTALL_FNS
if [ "$GROUPS_PROVIDED" -eq 0 ]; then
    INSTALL_FNS=("${INSTALL_FNS_ALL[@]}")
else
    if [ -z "$REQUESTED_GROUPS" ]; then
        echo "ERROR: --groups= cannot be empty" >&2
        exit 1
    fi

    # Build the set of valid group names from INSTALL_FNS_ALL.
    declare -A VALID_GROUPS=()
    for fn in "${INSTALL_FNS_ALL[@]}"; do
        VALID_GROUPS["${fn#install_}"]=1
    done

    # Build a lookup set from the requested groups so order on CLI doesn't matter.
    declare -A REQUESTED_SET=()
    IFS=',' read -ra _req_arr <<< "$REQUESTED_GROUPS"
    for g in "${_req_arr[@]}"; do
        if [ -z "${VALID_GROUPS[$g]:-}" ]; then
            echo "ERROR: unknown group '$g'" >&2
            echo "       valid groups: ${!VALID_GROUPS[*]}" >&2
            exit 1
        fi
        REQUESTED_SET["$g"]=1
    done

    # Walk INSTALL_FNS_ALL in canonical order; include only requested ones.
    for fn in "${INSTALL_FNS_ALL[@]}"; do
        group="${fn#install_}"
        [ -n "${REQUESTED_SET[$group]:-}" ] && INSTALL_FNS+=("$fn")
    done
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "${INSTALL_FNS[@]}"
    exit 0
fi

for fn in "${INSTALL_FNS[@]}"; do
    "$fn"
done

# Make the tool PATH available to non-interactive SSH sessions (n8n, cron, ...).
# Tools live where their package manager puts them — no copying to /usr/local/bin:
#   Go toolchain         : /usr/local/go/bin (tarball)
#   Go-installed tools   : $TARGET_HOME/go/bin (`go install` with GOBIN pointing here)
#   pipx tools           : $TARGET_HOME/.local/bin (`as_user pipx install`)
#   npm globals & apt    : /usr/local/bin (default)
# All four are listed in /etc/environment, the Dockerfile ENV, and ~/.bashrc.
configure_system_path

# Update shell env (idempotent). $HOME here is the invoking user's home thanks
# to `sudo -H` semantics in the install path; pure-root invocations get root's
# home but the PATH expansion still resolves correctly at shell startup.
for line in \
    'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin' \
    'export GOBIN=$HOME/go/bin'
do
    if ! grep -qxF "$line" ~/.bashrc 2>/dev/null; then
        echo "$line" >> ~/.bashrc
    fi
done

# `go install` runs as root (we're past the sudo escalation) but writes to
# $GOBIN which now lives under the invoking user's home. Hand ownership back
# so the user can manage / upgrade those binaries without sudo.
if [ -d "$GOBIN" ] && [ "$TARGET_USER" != "root" ]; then
    sudo chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$GOBIN"
fi

# Permissions cleanup: preserve exec bit on dirs/binaries without over-escalating
sudo chmod -R u=rwX,go=rX "$INSTALL_DIR"
echo "[+] Setup finished."
