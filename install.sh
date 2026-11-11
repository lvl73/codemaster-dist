#!/usr/bin/env sh
# CodeMaster installer.
#
# Detects the OS, CPU and C library of this machine, downloads the matching
# release binaries (cm, cm-mcp, cm-daemon) plus the agent skills, checks that
# the downloaded build actually runs here, installs them into a directory on
# PATH and optionally starts the local SurrealDB service through Docker,
# Podman or docker compose. No root is needed: the default prefix is a
# writable directory already on PATH (~/.local/bin).
#
# The configuration file it leaves behind is the full template of the build:
# [storage] with the coordinates the installer verified, [embeddings] when
# the user enabled the channel interactively, and every remaining section at
# its default (T173) — `cm config explain` shows what is actually in effect.
#
# Typical usage:
#   curl -fsSL https://raw.githubusercontent.com/lvl73/codemaster-dist/master/install.sh -o install.sh
#   sh install.sh
#
# Non-interactive (CI / provisioning):
#   sh install.sh --yes --db docker --password "$(openssl rand -hex 16)"
#
# Everything can be driven by environment variables too; flags win.
# POSIX sh on purpose: the documented way to run this is `sh install.sh`.
set -eu

# Where the release assets live. The publishing repository of the source tree
# and the public distribution repository are different: assets and install.sh
# are what a user downloads, and pointing this at a private repository makes
# every external install fail with a 404 on the first request.
REPO="${CM_REPO:-lvl73/codemaster-dist}"
# --from-source needs the source repository, which is not the asset channel.
SOURCE_REPO="${CM_SOURCE_REPO:-$REPO}"
VERSION="${CM_VERSION:-latest}"
PREFIX="${CM_PREFIX:-}"
HOME_DIR="${CODEMASTER_HOME:-$HOME/.codemaster}"
DB="${CM_DB:-}"                                  # auto|compose|docker|podman|none
# Portability contract of the published binaries (ADR-0026): a build must run
# on a host with at least this glibc. The installer enforces it instead of
# letting the dynamic loader print its own message on every later run.
MIN_GLIBC="${CM_MIN_GLIBC:-2.35}"
LIBC="${CM_LIBC:-}"                              # gnu | musl (empty = detect)
TRIPLE=""                                        # empty = detect
TRIPLE_EXPLICIT=0
# The platform checks guard a *downloaded* asset. Building from source or
# installing prebuilt binaries (--local-bin) is still legitimate on a host the
# release does not cover, so those paths only warn.
ASSET_NEEDED=1
ALLOW_UNSUPPORTED=0                              # downgrade platform checks to warnings
UNVERIFIED_ASSETS=0                              # tolerate a missing .sha256 asset
PATH_MODE=""                                     # "" = ask/print | yes = edit rc | no = never
# SurrealDB parameters: intentionally without hardcoded defaults. Flags and
# env vars win; in an interactive run the installer asks for whatever is unset.
DB_IMAGE="${SURREALDB_IMAGE:-}"
DB_USER="${SURREALDB_USER:-}"
DB_PASS="${SURREALDB_PASSWORD:-}"
DB_PORT="${SURREALDB_PORT:-}"
# External instance (--db none): full connection coordinates, asked interactively.
DB_ENDPOINT="${CM_STORAGE_ENDPOINT:-}"
DB_MISSING_HINT=""
DB_NAMESPACE="${SURREALDB_NAMESPACE:-}"
DB_DATABASE="${SURREALDB_DATABASE:-}"
# Per-instance identity of the managed SurrealDB: the loopback port is the
# instance key. A second instance on another port never shares a volume, a
# container name or a compose project with the first one, and neither collides
# with a project-local dev docker-compose (same-name collision destroyed a
# developer's stack and made verify_storage reject the "new" password, because
# SurrealDB bootstraps the root user only once, at empty-storage init).
PROJECT=""        # cm-surrealdb-<port>, set once the port is resolved
CONTAINER=""      # cm-surrealdb-<port>
VOL=""            # cm-surrealdb-<port>-data
DB_EXPLICIT=0
DOCKER_OK=0
PODMAN_OK=0
ASSUME_YES=0
SKIP_RUN=0
FROM_SOURCE=0
LOCAL_BIN=""
NO_SKILLS=0
LOCAL_SKILLS=""
SKILLS_SRC=""
SKILLS_ASSET=cm-skills.tar.gz
DB_PASS_SET=0
TMPDIR_CM=""

log() { printf 'cm-install: %s\n' "$*"; }
die() { printf 'cm-install: error: %s\n' "$*" >&2; exit 1; }

SECRET_ECHO_OFF=0

cleanup() {
    # A terminal left with echo disabled is worse than a failed install.
    if [ "$SECRET_ECHO_OFF" = 1 ]; then
        stty echo 2>/dev/null || true
        printf '\n' >&2
    fi
    [ -n "$TMPDIR_CM" ] && [ -d "$TMPDIR_CM" ] && rm -rf "$TMPDIR_CM" || true
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
CodeMaster installer — detects OS/CPU/libc, installs the release binaries on PATH.

Usage: sh install.sh [options]

Platform:
  --triple SLUG        target triple instead of the detected one (advanced)
  --libc NAME          gnu | musl instead of the detected C library (advanced)
  --min-glibc VERSION  required glibc for the published build (default 2.35)
  --allow-unsupported  turn the OS/CPU/libc/glibc checks into warnings
  --allow-unverified   install a release asset even when its .sha256 is missing

Install:
  --prefix DIR         install directory (default: first writable directory
                       already on PATH, e.g. ~/.local/bin; /usr/local/bin only
                       for root or after an explicit confirmation)
  --path               also add the install directory to PATH by writing a
                       marked block into the shell startup file
  --no-path            never touch a shell startup file
  --version TAG        release tag to download (default: latest)
  --repo SLUG          GitHub owner/repo of the release assets (env CM_REPO)
  --home PATH          CodeMaster home (default: ~/.codemaster or $CODEMASTER_HOME)
  --from-source        build with cargo instead of downloading release assets
  --local-bin DIR      take binaries from DIR instead of downloading (advanced)
  --local-skills DIR   take the portable agent skills from DIR instead of the
                       release asset (e.g. .agents/skills in a checkout)
  --no-skills          do not install agent skills at all (binaries only)
  --no-run             do not start SurrealDB or the daemon
  -y, --yes            non-interactive: accept defaults
  -h, --help           show this help

SurrealDB:
  --db MODE            auto|compose|docker|podman|none (default: prompt or auto)
  --image REF          SurrealDB image (env SURREALDB_IMAGE; interactive prompt
                       defaults to surrealdb/surrealdb:v4.0.0, pinned by ADR-0017)
  --user NAME          SurrealDB username (env SURREALDB_USER; asked interactively)
  --password PASS      SurrealDB password (env SURREALDB_PASSWORD; asked interactively,
                       empty answer = generated)
  --port PORT          SurrealDB loopback port (env SURREALDB_PORT; asked interactively).
                       The port keys the managed instance: container
                       cm-surrealdb-<port>, volume cm-surrealdb-<port>-data, so
                       several instances can coexist on one machine.
  --endpoint HOST:PORT your own SurrealDB for --db none (env CM_STORAGE_ENDPOINT)
  --namespace NAME     storage namespace (env SURREALDB_NAMESPACE, prompt default: codemaster)
  --database NAME      storage database (env SURREALDB_DATABASE, prompt default: local)

Examples:
  sh install.sh                                   # interactive, no sudo needed
  sh install.sh --yes --db docker --password "$(openssl rand -hex 16)"
  sh install.sh --from-source --db compose
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=$2; shift 2 ;;
        --version) VERSION=$2; shift 2 ;;
        --repo) REPO=$2; [ -n "${CM_SOURCE_REPO:-}" ] || SOURCE_REPO=$2; shift 2 ;;
        --db) DB=$2; DB_EXPLICIT=1; shift 2 ;;
        --image) DB_IMAGE=$2; shift 2 ;;
        --user) DB_USER=$2; shift 2 ;;
        --password) DB_PASS=$2; DB_PASS_SET=1; shift 2 ;;
        --port) DB_PORT=$2; shift 2 ;;
        --endpoint) DB_ENDPOINT=$2; shift 2 ;;
        --namespace) DB_NAMESPACE=$2; shift 2 ;;
        --database) DB_DATABASE=$2; shift 2 ;;
        --home) HOME_DIR=$2; shift 2 ;;
        --triple) TRIPLE=$2; TRIPLE_EXPLICIT=1; shift 2 ;;
        --libc) LIBC=$2; shift 2 ;;
        --min-glibc) MIN_GLIBC=$2; shift 2 ;;
        --allow-unsupported) ALLOW_UNSUPPORTED=1; shift ;;
        --allow-unverified) UNVERIFIED_ASSETS=1; shift ;;
        --path) PATH_MODE=yes; shift ;;
        --no-path) PATH_MODE=no; shift ;;
        --from-source) FROM_SOURCE=1; ASSET_NEEDED=0; shift ;;
        --local-bin) LOCAL_BIN=$2; ASSET_NEEDED=0; shift 2 ;;
        --local-skills) LOCAL_SKILLS=$2; shift 2 ;;
        --no-skills) NO_SKILLS=1; shift ;;
        --no-run) SKIP_RUN=1; shift ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

case "$DB" in
    ""|auto|compose|docker|podman|none) ;;
    *) die "invalid --db: $DB (use auto|compose|docker|podman|none)" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# Reads a secret without echoing it, portably. The silent-read option that some
# shells offer is not POSIX, and this script is documented to run as
# `sh install.sh` — under dash (= Ubuntu's /bin/sh) that option fails outright.
# Where the terminal cannot be configured, the value is simply echoed while
# typed — the same behaviour the managed-instance prompt has always had.
read_secret() { # VAR
    if [ -t 0 ] && have stty && stty -echo 2>/dev/null; then
        SECRET_ECHO_OFF=1
        read -r "$1" || { stty echo 2>/dev/null || true; SECRET_ECHO_OFF=0; return 1; }
        stty echo 2>/dev/null || true
        SECRET_ECHO_OFF=0
        printf '\n'
        return 0
    fi
    read -r "$1"
}

interactive() { [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; }

gen_pass() {
    if have openssl; then openssl rand -hex 16
    else head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

FETCH_ERR=""
fetch() { # fetch URL DEST  (0 on success; the tool's own message is kept in FETCH_ERR)
    if have curl; then FETCH_ERR=$(curl -fsSL "$1" -o "$2" 2>&1)
    else FETCH_ERR=$(wget -qO "$2" "$1" 2>&1); fi
    if [ -n "$FETCH_ERR" ]; then return 1; fi
    return 0
}

# ---------------------------------------------------------------- platform
# sort -V orders dotted versions; the installer stays POSIX sh, so no bash-only
# version comparison.
version_lt() { # version_lt A B → true when A is strictly older than B
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

platform_refuse() { # platform_refuse MESSAGE — the escape hatches are the point
    # A refusal is an error: both lines go to stderr, so `install.sh 2>log`
    # captures the whole reason and a caller can grep it.
    printf 'cm-install: error: %s\n' "$1" >&2
    printf 'cm-install: error: this machine needs a build this release does not publish; options: --from-source (builds for exactly this host), --triple/--libc (another published asset), --allow-unsupported (install without the check)\n' >&2
    exit 1
}

# Only a downloaded asset has to match this machine: a source build or
# --local-bin input is the operator's own responsibility.
asset_refuse() {
    if [ "$ASSET_NEEDED" = 1 ]; then
        platform_refuse "$1"
    else
        log "warning: $1"
    fi
}

glibc_version() {
    # "ldd (Ubuntu GLIBC 2.35-0ubuntu3.13) 2.35", "ldd (GNU libc) 2.31":
    ldd --version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | tail -n 1 || true
}

detect_libc() { # gnu | musl | macos
    if [ -n "$LIBC" ]; then
        printf '%s' "$LIBC"
        return
    fi
    if [ "$OS" = darwin ]; then
        printf 'macos'
        return
    fi
    if have ldd && ldd --version 2>&1 | head -n 1 | grep -qi 'musl'; then
        printf 'musl'
        return
    fi
    for candidate in /lib/ld-musl-*.so.1 /usr/lib/ld-musl-*/libc.so.1; do
        if [ -e "$candidate" ]; then
            printf 'musl'
            return
        fi
    done
    printf 'gnu'
}

# The triple names the release asset, so it is derived, never guessed: an
# x86_64 host that is handed an aarch64 tar.gz fails at the first exec.
detect_triple() {
    OS=$(uname -s)
    ARCH=$(uname -m)
    case "$OS" in
        Linux) OS=linux ;;
        Darwin) OS=darwin ;;
        *) TRIPLE_EXPLICIT=1 ;;
    esac
    case "$ARCH" in
        x86_64|amd64) CPU=x86_64 ;;
        aarch64|arm64) CPU=aarch64 ;;
        *) CPU=$ARCH; asset_refuse "unsupported CPU: $ARCH (published builds cover x86_64 and aarch64)" ;;
    esac
    LIBC=$(detect_libc)
    if [ "$TRIPLE_EXPLICIT" = 1 ]; then
        log "using --triple $TRIPLE"
        return
    fi
    case "$OS" in
        darwin)
            asset_refuse "no macOS assets in this release: the publish workflow has no macOS runners yet"
            TRIPLE="$CPU-apple-darwin"
            ;;
        linux)
            case "$LIBC" in
                gnu) TRIPLE="$CPU-unknown-linux-gnu" ;;
                musl) TRIPLE="$CPU-unknown-linux-musl" ;;
                *) die "unknown C library: $LIBC (--libc gnu|musl sets it explicitly)" ;;
            esac
            ;;
        *)
            asset_refuse "unsupported OS: $OS (published builds cover Linux; on Windows use WSL)"
            TRIPLE="$CPU-$OS-$LIBC"
            ;;
    esac
}

# A glibc host older than the published baseline is the failure users see as
# "weak version GLIBC_2.39 not found" or "version not found" from ld.so, and a
# musl host cannot start a glibc build at all. Detect it before anything is
# installed rather than leaving a binary that only prints errors.
check_platform() {
    if [ "$LIBC" != gnu ]; then
        log "platform: $OS $CPU, libc $LIBC"
        return 0
    fi
    host=$(glibc_version)
    [ -n "$host" ] || { log "warning: cannot read the glibc version, skipping the check"; return 0; }
    if version_lt "$host" "$MIN_GLIBC"; then
        if [ "$ALLOW_UNSUPPORTED" = 1 ]; then
            log "warning: glibc $host is older than the $MIN_GLIBC baseline"
            return 0
        fi
        platform_refuse "this host has glibc $host, the published $TRIPLE build requires $MIN_GLIBC or newer"
    fi
    log "platform: $OS $CPU, glibc $host (>= $MIN_GLIBC)"
}

elf_machine() { # FILE → x86_64 | aarch64 | not-elf | other
    magic=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
    [ "$magic" = "7f454c46" ] || { printf 'not-elf'; return; }
    # e_machine, little-endian ELF64: 0x3e = x86_64, 0xb7 = aarch64.
    case "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')" in
        3e00) printf 'x86_64' ;;
        b700) printf 'aarch64' ;;
        *) printf 'other' ;;
    esac
}

# Run the downloaded build before it can reach PATH: a wrong libc, a wrong CPU
# or a missing shared library all fail here with one clear message instead of
# on every later invocation.
verify_binaries() { # DIR
    for bin in cm cm-mcp cm-daemon; do
        [ -f "$1/$bin" ] || die "the asset for $TRIPLE does not contain $bin"
        if [ "$OS" = linux ] && [ "$ALLOW_UNSUPPORTED" = 0 ]; then
            got=$(elf_machine "$1/$bin")
            [ "$got" = "$CPU" ] || platform_refuse "$1/$bin is $got, this CPU is $CPU"
        fi
    done
    if ! loader_out=$( { "$1/cm" --version >/dev/null; } 2>&1 ); then
        platform_refuse "the downloaded cm does not run here: $(printf '%s' "$loader_out" | head -n 3 | tr '\n' ' ')"
    fi
    if [ -n "$loader_out" ]; then
        log "warning: the dynamic loader reported: $loader_out"
    fi
    log "downloaded build verified: $("$1/cm" --version 2>/dev/null)"
}

# ---------------------------------------------------------------- binaries
# A release asset without its checksum is not "verified": silently installing
# whatever the CDN returned is how a broken or replaced tarball becomes a
# running daemon. sha256sum/shasum are both accepted; the check can be waived
# once per run with --allow-unverified.
verify_checksum() { # FILE_DIR ASSET_NAME BASE_URL — the checksum asset drops the
    # .tar.gz suffix: release.yml publishes cm-<triple>.sha256, not ….tar.gz.sha256.
    checksum_asset=${2%.tar.gz}.sha256
    if ! fetch "$3/$checksum_asset" "$1/$checksum_asset"; then
        if [ "$UNVERIFIED_ASSETS" = 1 ]; then
            log "warning: no $checksum_asset published, installing unverified (--allow-unverified)"
            return 0
        fi
        die "$2 has no published checksum ($checksum_asset); refusing to install it (re-run with --allow-unverified if you trust the channel)"
    fi
    want=$(awk '{print $1}' "$1/$checksum_asset")
    if have sha256sum; then got=$(sha256sum "$1/$2" | awk '{print $1}')
    elif have shasum; then got=$(shasum -a 256 "$1/$2" | awk '{print $1}')
    elif [ "$UNVERIFIED_ASSETS" = 1 ]; then
        log "warning: no sha256 tool found, skipping verification (--allow-unverified)"
        return 0
    else
        die "neither sha256sum nor shasum is available to verify $2 (install coreutils, or pass --allow-unverified)"
    fi
    [ "$got" = "$want" ] || die "checksum mismatch for $2 (expected $want, got $got): the download is corrupt, nothing was installed"
    log "checksum verified: $2"
}

install_from_release() {
    detect_triple
    check_platform
    asset="cm-${TRIPLE}.tar.gz"
    if [ "$VERSION" = latest ]; then
        base="https://github.com/$REPO/releases/latest/download"
    else
        base="https://github.com/$REPO/releases/download/$VERSION"
    fi
    TMPDIR_CM=$(mktemp -d)
    log "downloading $base/$asset"
    if ! fetch "$base/$asset" "$TMPDIR_CM/$asset"; then
        die "no $asset in $REPO ($VERSION): ${FETCH_ERR:-not found}. Known assets are published for linux x86_64/aarch64; detected here: $OS $CPU/$LIBC. Options: --from-source, --repo, --triple"
    fi
    verify_checksum "$TMPDIR_CM" "$asset" "$base"
    tar -xzf "$TMPDIR_CM/$asset" -C "$TMPDIR_CM"
    SRC_DIR=$TMPDIR_CM
    # The published build has to work on THIS machine, not merely unpack: the
    # loader, the CPU and the C library all fail in ways a user would otherwise
    # read as "cm is broken" on every later run.
    verify_binaries "$TMPDIR_CM"
    # Скилы — отдельный ассет: они меняются чаще Rust-кода и могут отсутствовать,
    # не ломая установку бинарников.
    if fetch "$base/$SKILLS_ASSET" "$TMPDIR_CM/$SKILLS_ASSET"; then
        verify_checksum "$TMPDIR_CM" "$SKILLS_ASSET" "$base"
        mkdir -p "$TMPDIR_CM/skills-asset"
        tar -xzf "$TMPDIR_CM/$SKILLS_ASSET" -C "$TMPDIR_CM/skills-asset"
        SKILLS_SRC="$TMPDIR_CM/skills-asset/skills"
    else
        log "warning: release has no $SKILLS_ASSET; skipping skills (binaries are installed)"
    fi
}

install_from_source() {
    have cargo || die "cargo not found; install Rust (rustup) or download release assets"
    if [ ! -f Cargo.toml ]; then
        TMPDIR_CM=$(mktemp -d)
        log "cloning https://github.com/$SOURCE_REPO"
        git clone --depth 1 "https://github.com/$SOURCE_REPO.git" "$TMPDIR_CM/repo" \
            || die "git clone failed: $SOURCE_REPO may be private or need credentials. Run the installer inside your own checkout, or pass --local-bin DIR with binaries you built."
        cd "$TMPDIR_CM/repo"
    fi
    log "building release binaries (this can take a while)"
    cargo build --release --locked -p cm-cli -p cm-mcp -p cm-daemon
    SRC_DIR=target/release
    SKILLS_SRC=.agents/skills
}

in_path() { # in_path DIR — is DIR an element of PATH
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    return 1
}

# A single-user tool must not need root: prefer a directory that is writable
# AND already on PATH, so the install needs no follow-up at all.
pick_prefix() {
    if [ -n "$PREFIX" ]; then return 0; fi
    for candidate in "$HOME/.local/bin" "$HOME/.cargo/bin" /usr/local/bin; do
        if [ -d "$candidate" ] && [ -w "$candidate" ] && in_path "$candidate"; then
            PREFIX=$candidate
            return 0
        fi
    done
    if [ "$(id -u)" = 0 ] || [ -w /usr/local/bin ]; then
        PREFIX=/usr/local/bin
        return 0
    fi
    PREFIX="$HOME/.local/bin"
    return 0
}

PATH_MARKER='# >>> CodeMaster: install directory on PATH >>>'

shell_rc() { # startup file of the interactive shell of this user
    case "${SHELL:-}" in
        */zsh) printf '%s' "$HOME/.zshrc" ;;
        */bash) printf '%s' "$HOME/.bashrc" ;;
        *) printf '%s' "$HOME/.profile" ;;
    esac
}

# "Installed" means reachable as `cm`: a fresh ~/.local/bin stays invisible
# until some startup file mentions it (Debian/Ubuntu ~/.profile does, many
# others do not). A dotfile is edited only on an explicit --path or an
# interactive confirmation, never silently and never twice.
ensure_on_path() { # ensure_on_path DIR
    # PATH entries and the written export must be absolute: a relative --prefix
    # would install fine and then name a directory that only exists from $PWD.
    dir=$(cd "$1" 2>/dev/null && pwd) || dir=$1
    if in_path "$dir"; then
        log "on PATH: $dir"
        return 0
    fi
    hint="export PATH=\"$dir:\$PATH\""
    if [ "$PATH_MODE" = no ]; then
        log "warning: $dir is not in PATH (--no-path); add it yourself: $hint"
        return 0
    fi
    if [ "$dir" = "$HOME/.local/bin" ] && [ -f "$HOME/.profile" ] \
       && grep -q '\.local/bin' "$HOME/.profile" 2>/dev/null; then
        log "$dir will be on PATH in a new shell (~/.profile already handles it)"
        return 0
    fi
    rc=$(shell_rc)
    if [ "$PATH_MODE" != yes ]; then
        if interactive; then
            printf 'add %s to PATH in %s? [Y/n] ' "$dir" "$rc"
            read -r ans
            case "$ans" in
                [nN]*) log "not touching $rc; add it yourself: $hint" ;;
                *) PATH_MODE=yes ;;
            esac
        fi
    fi
    if [ "$PATH_MODE" != yes ]; then
        log "warning: $dir is not in PATH; run: $hint   (or re-run with --path to write it into $rc)"
        return 0
    fi
    if [ -e "$rc" ] && [ ! -w "$rc" ]; then
        log "warning: $rc is not writable; add it yourself: $hint"
        return 0
    fi
    if ! grep -qF "$PATH_MARKER" "$rc" 2>/dev/null; then
        printf '\n%s\n%s\n# <<< CodeMaster <<<\n' "$PATH_MARKER" "$hint" >> "$rc" \
            || { log "warning: cannot write $rc; add it yourself: $hint"; return 0; }
        log "PATH: added $dir to $rc"
    else
        log "PATH: $rc already has the CodeMaster block"
    fi
    log "open a new shell, or run: $hint"
    return 0
}

run_install() { # run_install SRC DEST
    if [ "$(dirname "$2")" = /usr/local/bin ] && [ ! -w /usr/local/bin ]; then
        sudo install -m 0755 "$1" "$2"
    else
        install -m 0755 "$1" "$2"
    fi
}

install_binaries() {
    mkdir -p "$PREFIX"
    for bin in cm cm-mcp cm-daemon; do
        [ -f "$SRC_DIR/$bin" ] || die "$bin not found in $SRC_DIR"
        run_install "$SRC_DIR/$bin" "$PREFIX/$bin"
    done
    log "installed $PREFIX/cm $PREFIX/cm-mcp $PREFIX/cm-daemon"
    ensure_on_path "$PREFIX"
    "$PREFIX/cm" --version >/dev/null 2>&1 \
        || die "the installed binary does not run: $PREFIX/cm --version failed"
}

# ---------------------------------------------------------------- surrealdb
install_skills() {
    # Скилы — данные, а не код: они кладутся в домашний каталог CodeMaster и уже
    # оттуда раскладываются по агентам командой `cm skill install` (T153, T154).
    [ "$NO_SKILLS" = 1 ] && { log "--no-skills: agent skills not installed"; return 0; }
    source_dir=$LOCAL_SKILLS
    [ -z "$source_dir" ] && source_dir=$SKILLS_SRC
    if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
        log "warning: no skills source found; run 'cm skill install' later after fetching skills"
        return 0
    fi
    dest="$HOME_DIR/skills"
    mkdir -p "$dest"
    # Копируем содержимое, а не сам каталог: повторный запуск сходится к тому же
    # состоянию (правило 7 AGENTS.md).
    # Только каталоги скилов: README.md источника — документация репозитория,
    # а не скил, и в домашний каталог ему идти не нужно.
    for item in "$source_dir"/*/; do
        [ -d "$item" ] || continue
        name=$(basename "$item")
        [ "$name" = "skills-manifest.json" ] && continue
        rm -rf "${dest:?}/$name"
        cp -R "$item" "$dest/$name"
    done
    if [ -f "$source_dir/skills-manifest.json" ]; then
        cp "$source_dir/skills-manifest.json" "$dest/skills-manifest.json"
    elif have python3 && [ -f tools/skills_manifest.py ]; then
        # «latest» — имя релизного канала, а не версия: в манифесте должен быть
        # настоящий тег либо metка локальной сборки.
        case "$VERSION" in
            latest|"") skills_version=local-build ;;
            *) skills_version=${VERSION#v} ;;
        esac
        python3 tools/skills_manifest.py "$dest" --version "$skills_version" \
            --out "$dest/skills-manifest.json" >/dev/null 2>&1 || true
    fi
    if [ -f "$dest/skills-manifest.json" ]; then
        count=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["skills"]))' "$dest/skills-manifest.json" 2>/dev/null || echo '?')
        log "skills: $count → $dest"
    else
        log "skills copied to $dest (no manifest: cm skill ls works, status --check cannot version them)"
    fi
}

# The docker CLI can exist while its daemon is unreachable: on Ubuntu with
# Docker Desktop the socket is ~/.docker/run/docker.sock (or the legacy
# ~/.docker/desktop/docker.sock), resolved through the current user's docker
# context — which a sudo/root shell does not see, so the CLI falls back to the
# non-existent /var/run/docker.sock. Probe, then try the known Desktop sockets
# and every configured context endpoint before declaring docker dead.
probe_docker() {
    have docker || return 1
    if docker info >/dev/null 2>&1; then return 0; fi
    cands=""
    for sock in "$HOME/.docker/run/docker.sock" "$HOME/.docker/desktop/docker.sock"; do
        [ -S "$sock" ] && cands="$cands unix://$sock"
    done
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        uhome=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        for sock in "$uhome/.docker/run/docker.sock" "$uhome/.docker/desktop/docker.sock"; do
            [ -S "$sock" ] && cands="$cands unix://$sock"
        done
    fi
    for ctx in $(docker context ls -q 2>/dev/null); do
        host=$(docker context inspect -f '{{.Endpoints.docker.Host}}' "$ctx" 2>/dev/null)
        case "$host" in unix://*) cands="$cands $host" ;; esac
    done
    for cand in $cands; do
        if DOCKER_HOST=$cand docker info >/dev/null 2>&1; then
            DOCKER_HOST=$cand; export DOCKER_HOST
            log "docker daemon reached via $DOCKER_HOST"
            return 0
        fi
    done
    return 1
}

# Resolves daemon availability before any mutation, so a machine with
# Docker Desktop (or no runtime at all) fails with instructions instead of
# half-installed binaries and a raw "cannot connect to the docker daemon".
preflight_runtimes() {
    [ "$SKIP_RUN" = 1 ] && return 0
    [ "$DB" = none ] && return 0
    probe_docker && DOCKER_OK=1
    if have podman && podman info >/dev/null 2>&1; then PODMAN_OK=1; fi
    if [ "$DOCKER_OK" = 0 ] && [ "$PODMAN_OK" = 0 ]; then
        # shellcheck disable=SC2016  # $HOME в цитируемом совете не раскрывается намеренно
        die "no usable container runtime: $(have docker && printf 'the docker CLI is installed but no daemon is reachable through it.\n  Docker Desktop: start it, or enable Settings -> Advanced ->\n  \"Allow the default Docker socket to be used\", or re-run as your desktop\n  user (not sudo) / export DOCKER_HOST=unix://\$HOME/.docker/run/docker.sock.\n  ' || printf 'docker is not installed.\n')$(have podman || printf 'podman is not installed.\n')Start SurrealDB yourself and re-run with --db none, or fix the runtime above."
    fi
}

pick_db_mode() {
    [ -n "$DB" ] && { [ "$DB" != auto ] && return; }
    if [ "$DOCKER_OK" = 1 ] && docker compose version >/dev/null 2>&1; then DB=compose; return; fi
    if [ "$DOCKER_OK" = 1 ]; then DB=docker; return; fi
    if [ "$PODMAN_OK" = 1 ]; then DB=podman; return; fi
    DB=none
}

# The managed instance is keyed by its loopback port: same port = same
# container/volume (a re-run converges), different port = a separate instance.
# The compose project is per-instance too: sharing one project would give two
# installs the same (project, service) identity, and the second `up -d` would
# recreate the first instance's container.
instance_names() {
    PROJECT=cm-surrealdb-$DB_PORT
    CONTAINER=cm-surrealdb-$DB_PORT
    VOL=cm-surrealdb-$DB_PORT-data
}

# SurrealDB sets the root password only when the storage directory is empty;
# restarting with another --pass silently keeps the original one. When the
# instance already exists, ask for the password that actually works instead of
# collecting one that cannot (and offer an explicit, confirmed reset).
reuse_existing_storage() {
    "$RUNNER" volume inspect "$VOL" >/dev/null 2>&1 || return 0
    log "existing storage found: volume $VOL (container $CONTAINER)"
    log "its root password was set at the first init; restarting with a different password does not change it"
    interactive || return 0
    printf 'reuse this storage? [Y/n] '
    read -r ans
    case "${ans:-y}" in
        [nN]*)
            printf 'a fresh storage deletes every indexed project in %s.\ntype the volume name to confirm: ' "$VOL"
            read -r conf
            [ "$conf" = "$VOL" ] || die "aborted; nothing was deleted"
            "$RUNNER" rm -f "$CONTAINER" >/dev/null 2>&1 || true
            "$RUNNER" volume rm "$VOL" >/dev/null || die "cannot remove volume $VOL"
            log "volume $VOL removed; initializing a fresh storage"
            log "note: a reset volume needs the new credentials in $HOME_DIR/config.toml; this run rewrites [storage] when it finishes"
            ;;
        *)
            [ -n "$DB_USER" ] || { printf 'SurrealDB username of the existing storage (no default): '
                read -r DB_USER; }
            if [ -z "$DB_PASS" ]; then
                printf 'password of the existing storage (the one set at its first init): '
                read -r DB_PASS
                [ -n "$DB_PASS" ] || die "no password provided; re-run and reuse with the right password, or reset the volume"
            fi
            ;;
    esac
}

# Port is the instance key, so a different container publishing it is a real
# conflict (e.g. an instance from an older installer layout, or a dev stack).
other_container_on_port() {
    "$RUNNER" ps -a --format '{{.Names}} {{.Ports}}' 2>/dev/null \
        | awk -v me="$CONTAINER" -v p="127.0.0.1:$DB_PORT->" \
              '$1 != me && index($0, p) { print $1; exit }'
}

ask_db_mode() {
    [ "$ASSUME_YES" = 1 ] && return
    [ -t 0 ] || return
    [ -n "${CM_DB:-}" ] && return
    [ "$DB_EXPLICIT" = 1 ] && return
    cat <<EOF
How should the local SurrealDB service be started?
  1) compose  - write $HOME_DIR/docker-compose.yml and docker compose up -d (recommended)
  2) docker   - plain docker run
  3) podman   - plain podman run
  4) none     - I run SurrealDB myself (or already do)
EOF
    printf 'choice [1]: '
    read -r ans
    case "${ans:-1}" in
        1) DB=compose ;; 2) DB=docker ;; 3) DB=podman ;; 4) DB=none ;; *) die "invalid choice: $ans" ;;
    esac
    return 0
}

wait_ready() {
    i=0
    while [ $i -lt 60 ]; do
        if "$RUNNER" exec "$CONTAINER" /surreal is-ready --endpoint "ws://localhost:8000" >/dev/null 2>&1; then
            log "SurrealDB is ready on 127.0.0.1:$DB_PORT"
            return 0
        fi
        i=$((i + 1)); sleep 1
    done
    die "SurrealDB did not become ready in 60s; check: $RUNNER logs $CONTAINER"
}

# Resolves the SurrealDB parameters. Port, namespace and database are
# *proposals* the installer records into config.toml; the username and the
# password are never invented: CodeMaster has no built-in credentials
# (ADR-0027), so a scripted run has to say them (--password "" generates one)
# and an interactive run has to type them.
ask_db_params() {
    if [ "$DB" = none ]; then
        DB_MISSING_HINT=" (this instance is external: pass --endpoint, --user and --password)"
    else
        DB_MISSING_HINT=" (pass --user and --password, or --password \" \" to generate one)"
    fi
    img_def=surrealdb/surrealdb:v4.0.0
    ns_def=codemaster; db_def=local
    if [ "$DB" = none ]; then
        if interactive; then
            [ -n "$DB_ENDPOINT" ] || { printf 'Your SurrealDB endpoint host:port (no default): '
                read -r DB_ENDPOINT; }
            [ -n "$DB_USER" ] || { printf 'SurrealDB username (no default): '; read -r DB_USER; }
            [ -n "$DB_PASS" ] || { printf 'SurrealDB password for %s (no default): ' "${DB_USER:-?}"
                read_secret DB_PASS; }
            [ -n "$DB_NAMESPACE" ] || { printf 'Namespace [%s]: ' "$ns_def"
                read -r DB_NAMESPACE; DB_NAMESPACE=${DB_NAMESPACE:-$ns_def}; }
            [ -n "$DB_DATABASE" ] || { printf 'Database [%s]: ' "$db_def"
                read -r DB_DATABASE; DB_DATABASE=${DB_DATABASE:-$db_def}; }
        fi
        DB_NAMESPACE=${DB_NAMESPACE:-$ns_def}
        DB_DATABASE=${DB_DATABASE:-$db_def}
        require_credentials
        return 0
    fi

    [ -n "$DB_IMAGE" ] || DB_IMAGE=$img_def
    if interactive; then
        printf 'SurrealDB image [%s]: ' "$DB_IMAGE"; read -r ans
        [ -n "$ans" ] && DB_IMAGE=$ans
        if [ -z "$DB_PORT" ]; then
            printf 'SurrealDB loopback port [8001]: '; read -r DB_PORT
            DB_PORT=${DB_PORT:-8001}
        fi
    fi
    DB_PORT=${DB_PORT:-8001}
    DB_NAMESPACE=${DB_NAMESPACE:-$ns_def}
    DB_DATABASE=${DB_DATABASE:-$db_def}
    DB_ENDPOINT=127.0.0.1:$DB_PORT
    # Port is known → the instance has a name; an existing storage changes what
    # the credentials questions mean (reuse asks for the original password, and
    # its reset is confirmed by typing the volume name).
    instance_names
    reuse_existing_storage
    if interactive; then
        [ -n "$DB_USER" ] || { printf 'SurrealDB root username (no default): '; read -r DB_USER; }
        if [ -z "$DB_PASS" ]; then
            printf 'SurrealDB root password [Enter = generate]: '; read -r DB_PASS
        fi
    fi
    # An explicit empty --password is the documented way to ask for a generated
    # secret in a scripted run; it is not the same as "not provided".
    if [ -z "$DB_PASS" ] && [ "$DB_PASS_SET" = 1 ]; then
        DB_PASS=$(gen_pass)
        log "generated SurrealDB password: $DB_PASS"
    fi
    require_credentials
    return 0
}

# Fails with the exact flags to add, instead of writing a configuration that
# cannot connect. Root/root was never a working answer on a real machine: it is
# what made a sudo install and a user install look like two different products.
require_credentials() {
    missing=""
    [ -n "$DB_ENDPOINT" ] || missing="$missing --endpoint"
    [ -n "$DB_USER" ] || missing="$missing --user"
    [ -n "$DB_PASS" ] || missing="$missing --password"
    [ -z "$missing" ] || die "the database coordinates are required (CodeMaster has no built-in endpoint or credentials):$missing${DB_MISSING_HINT:-}"
}


# Checks that the daemon will actually be able to connect: SurrealDB REST
# /status with basic auth. ATTEMPTS guards against a container that is ready
# on the socket but still initializing credentials. A 401/403 means the
# endpoint is alive and the credentials are wrong — retrying cannot help, and
# the message says so instead of blaming "dead endpoint".
verify_storage() {
    attempts=${1:-3}
    if ! have curl; then
        log "warning: curl not found, cannot verify storage credentials before daemon start"
        return 0
    fi
    i=0; code=000
    while [ $i -lt "$attempts" ]; do
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -u "$DB_USER:$DB_PASS" "http://$DB_ENDPOINT/status" 2>/dev/null || true)
        code=${code:-000}
        case "$code" in 2*) log "storage verified: $DB_ENDPOINT accepts user '$DB_USER'"; return 0 ;; esac
        case "$code" in 401|403) break ;; esac
        i=$((i + 1)); sleep 2
    done
    case "$code" in
        401|403)
            if [ -n "$VOL" ]; then
                die "SurrealDB at $DB_ENDPOINT is alive but rejects user '$DB_USER': an existing storage keeps the root password of its first initialization. Re-run install.sh and enter that password, or reset this instance (deletes every indexed project): $RUNNER rm -f $CONTAINER; $RUNNER volume rm $VOL"
            else
                die "SurrealDB at $DB_ENDPOINT is alive but rejects user '$DB_USER': wrong credentials for your own instance; fix them and re-run install.sh"
            fi
            ;;
        000)
            die "cannot reach SurrealDB at $DB_ENDPOINT: nothing is listening (wrong port or dead container); check: ${RUNNER:-docker} ps and ${RUNNER:-docker} logs ${CONTAINER:-<container>}"
            ;;
        *)
            die "SurrealDB at $DB_ENDPOINT answered HTTP $code to /status for user '$DB_USER'"
            ;;
    esac
}

start_surreal() {
    pick_db_mode
    ask_db_mode
    case "$DB" in
        compose|docker) have docker || die "docker not found"
            [ "$DOCKER_OK" = 1 ] || die "the docker CLI cannot reach a daemon (Docker Desktop keeps its socket at \$HOME/.docker/run/docker.sock; start it or enable the default-socket integration, run install.sh as the desktop user without sudo, or export DOCKER_HOST); or choose --db podman/none" ;;
        podman)  have podman || die "podman not found"
                 [ "$PODMAN_OK" = 1 ] || die "podman is installed but its service is not reachable; start it or choose --db none" ;;
        none)    ask_db_params
                 log "using your own SurrealDB at $DB_ENDPOINT"; verify_storage; return ;;
    esac
    case "$DB" in docker|compose) RUNNER=docker ;; podman) RUNNER=podman ;; esac
    # ask_db_params needs $RUNNER: the instance is keyed by the port resolved
    # there, and an existing storage must be detected before the password is asked.
    ask_db_params

    conflicting=$(other_container_on_port)
    [ -z "$conflicting" ] || die "container '$conflicting' already publishes 127.0.0.1:$DB_PORT; stop it ($RUNNER rm -f $conflicting) or pick another port"

    if "$RUNNER" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        log "container $CONTAINER already running; leaving it untouched"
        verify_storage
        return
    fi

    if [ "$DB" = compose ]; then
        mkdir -p "$HOME_DIR"
        cat > "$HOME_DIR/docker-compose.yml" <<EOF
services:
  surrealdb:
    image: $DB_IMAGE
    container_name: $CONTAINER
    command: start --user $DB_USER --pass $DB_PASS --bind 0.0.0.0:8000 surrealkv:/data/db
    ports:
      - "127.0.0.1:$DB_PORT:8000"
    volumes:
      - surrealdb-data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/surreal", "is-ready", "--endpoint", "ws://localhost:8000"]
      interval: 5s
      timeout: 3s
      retries: 20

volumes:
  surrealdb-data:
    # Explicit name: compose otherwise prefixes <project>_ and the installer
    # would look for (and reuse) a volume that does not exist.
    name: $VOL
EOF
        log "wrote $HOME_DIR/docker-compose.yml"
        docker compose -f "$HOME_DIR/docker-compose.yml" -p "$PROJECT" up -d
    else
        if "$RUNNER" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
            log "starting existing container $CONTAINER"
            "$RUNNER" start "$CONTAINER" >/dev/null
        else
            log "starting $CONTAINER via $RUNNER"
            "$RUNNER" run -d --name "$CONTAINER" \
                -p "127.0.0.1:$DB_PORT:8000" \
                -v "$VOL:/data" \
                --restart unless-stopped \
                "$DB_IMAGE" \
                start --user "$DB_USER" --pass "$DB_PASS" --bind 0.0.0.0:8000 surrealkv:/data/db >/dev/null
        fi
    fi
    wait_ready
    verify_storage 5
}

# Records the coordinates the installer verified. This is not optional and not
# conditional on "non-default" values: the product has no built-in endpoint or
# credentials (ADR-0027), so a machine left without [storage] has a daemon that
# cannot start. Everything else in the file (comments, other sections) is
# preserved; only the [storage] section is replaced, and the previous file is
# kept as a timestamped backup when that replacement discards values.
write_storage_config() {
    mkdir -p "$HOME_DIR"
    cfg="$HOME_DIR/config.toml"
    block="[storage]
mode = \"server\"
engine = \"surreal_db\"
endpoint = \"$(toml_escape "$DB_ENDPOINT")\"
username = \"$(toml_escape "$DB_USER")\"
password = \"$(toml_escape "$DB_PASS")\"
namespace = \"$(toml_escape "$DB_NAMESPACE")\"
database = \"$(toml_escape "$DB_DATABASE")\"
"
    tmp="$cfg.new.$$"
    # umask before the file exists: the secret must never be visible in the
    # window between creation and chmod.
    ( umask 077
      # An existing file is *copied minus the replaced section*, never emptied:
      # a config without [storage] yet still has to keep [daemon],
      # [embeddings] and every comment it may hold.
      if [ -f "$cfg" ]; then
          storage_without_section "$cfg" > "$tmp"
      else
          : > "$tmp"
      fi
      printf '\n%s' "$block" >> "$tmp" ) || die "cannot write $tmp"
    chmod 600 "$tmp"
    if [ -f "$cfg" ] && grep -qE '^\[storage(\.[^]]*)?\][[:space:]]*$' "$cfg"; then
        backup="$cfg.bak-$(date -u +%Y%m%dT%H%M%SZ)"
        cp -p "$cfg" "$backup" && log "previous configuration kept in $backup"
    fi
    mv -f "$tmp" "$cfg" || die "cannot replace $cfg"
    # Read our own output back: a daemon that cannot parse its configuration is
    # the failure mode this installer exists to prevent, and "it wrote a file"
    # is not evidence that the file is usable.
    stored=$(awk '
        /^\[storage(\.[^]]*)?\][[:space:]]*$/ { in_storage = 1; next }
        /^[[:space:]]*\[/                       { in_storage = 0 }
        in_storage && /^[a-z_]+ = /              { found++ }
        END                                      { print found + 0 }
    ' "$cfg")
    [ "$stored" = 7 ] \
        || die "$cfg: [storage] holds $stored key(s), expected 7 (mode, engine, endpoint, username, password, namespace, database)"
    # Имя файла известно заранее, поэтому `ls` здесь безопаснее, чем переносимая
    # замена stat -c / stat -f между GNU и BSD.
    # shellcheck disable=SC2012
    mode=$(ls -l "$cfg" | awk '{print substr($1, length($1)-2)}')
    [ "$mode" = 600 ] || log "warning: $cfg has mode $mode, expected 600 (credentials inside)"
    log "wrote $cfg (mode 600): endpoint $DB_ENDPOINT, user $DB_USER, namespace $DB_NAMESPACE, database $DB_DATABASE"
}

# Drops the [storage] section from a TOML file: the section ends at the next
# section header or at EOF. Anything else — comments included — is copied.
storage_without_section() { # SRC (stdout)
    awk '
        /^\[storage(\.[^]]*)?\][[:space:]]*$/ { in_storage = 1; next }
        /^[[:space:]]*\[/                       { in_storage = 0 }
        !in_storage                              { print }
    ' "$1"
}

# The [embeddings] counterpart: the section ends at the next header or EOF,
# everything else — comments included — is copied.
embeddings_without_section() { # SRC (stdout)
    awk '
        /^\[embeddings(\.[^]]*)?\][[:space:]]*$/ { in_embeddings = 1; next }
        /^[[:space:]]*\[/                         { in_embeddings = 0 }
        !in_embeddings                            { print }
    ' "$1"
}

# Asks for the essential embeddings settings (T173). The defaults are the
# reference stack this project is tested against — llama.cpp serving bge-m3
# with 1024-dim vectors — so pressing Enter through all three is a valid
# answer for that setup. Everything else (batching, token budgets, retries)
# stays at the model's defaults: the file is theirs to edit later.
# Non-interactive runs are never asked: the channel stays off, as before.
ask_embeddings_config() {
    interactive || return 0
    printf 'Enable embedding-based semantic search (a local OpenAI-compatible server, e.g. llama.cpp)? [y/N]: '
    read -r ans
    case "${ans:-n}" in
        [yY]*) ;;
        *) return 0 ;;
    esac
    printf 'Embeddings base_url [http://127.0.0.1:8081/v1]: '; read -r ans
    EMB_URL=${ans:-http://127.0.0.1:8081/v1}
    printf 'Embeddings model [bge-m3]: '; read -r ans
    EMB_MODEL=${ans:-bge-m3}
    printf 'Embeddings dimensions [1024]: '; read -r ans
    EMB_DIM=${ans:-1024}
    case "$EMB_DIM" in ''|*[!0-9]*) EMB_DIM=1024 ;; esac
    write_embeddings_config
    return 0
}

# Replaces the [embeddings] section the way [storage] is replaced: the
# installer records what the user chose, preserves the rest of the file,
# and keeps the owner-only mode because the same file holds the password.
write_embeddings_config() {
    cfg="$HOME_DIR/config.toml"
    block="[embeddings]
enabled = true
provider = \"openai-compatible\"
base_url = \"$(toml_escape "$EMB_URL")\"
model = \"$(toml_escape "$EMB_MODEL")\"
dimensions = $EMB_DIM
"
    tmp="$cfg.new.$$"
    ( umask 077
      # Same preservation rule as [storage]: copy the file minus the old
      # [embeddings] section, never start from empty over an existing config.
      if [ -f "$cfg" ]; then
          embeddings_without_section "$cfg" > "$tmp"
      else
          : > "$tmp"
      fi
      printf '\n%s' "$block" >> "$tmp" ) || die "cannot write $tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$cfg" || die "cannot replace $cfg"
    log "enabled embeddings: $EMB_MODEL ($EMB_DIM dims) at $EMB_URL"
    return 0
}

# Grows config.toml into the full template of this build (T173): 'cm config
# init --from-environment' re-renders the file from the configuration model,
# keeping the loaded values ([storage], and [embeddings] when the user just
# enabled it), so every key the daemon reads is visible with its default
# instead of being guessed from docs. The old file goes to a timestamped
# backup (SPEC-5 policy). A template problem must never break a working
# installation: failure warns and leaves the coordinates file in place.
expand_config_template() {
    if [ ! -x "$PREFIX/cm" ]; then
        log "warning: 'cm' is not executable yet; $HOME_DIR/config.toml keeps only what the installer wrote"
        return 0
    fi
    if "$PREFIX/cm" config init --from-environment --force >/dev/null 2>&1; then
        log "expanded $HOME_DIR/config.toml to the full template (every section, defaults inline)"
    else
        log "warning: 'cm config init' failed; the working config.toml is left as-is"
    fi
    return 0
}

# TOML basic-string escaping. A password containing a quote or a backslash is
# not exotic: without this the generated file is unparsable and the failure
# shows up as a daemon that cannot read its own configuration.
toml_escape() { # VALUE (stdout)
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# --no-run has to record coordinates too, without touching any container: the
# daemon needs them the first time it is started by hand.
resolve_coordinates() {
    if [ "$DB" != none ]; then
        DB_PORT=${DB_PORT:-8001}
        DB_ENDPOINT=127.0.0.1:$DB_PORT
    fi
    DB_NAMESPACE=${DB_NAMESPACE:-codemaster}
    DB_DATABASE=${DB_DATABASE:-local}
    DB_MISSING_HINT=" (with --db none: --endpoint --user --password; otherwise --user --password)"
    require_credentials
    return 0
}

# ---------------------------------------------------------------- main
# State, skills and the daemon socket belong to ONE user. An installer run
# through sudo writes them into the root home, and every later `cm` by the real
# user then looks like a fresh unconfigured machine — it does not fall back to
# the database that was set up, it reports the daemon as unavailable. Root is a
# legitimate choice on a shared machine, so this warns and shows how to
# converge rather than refusing.
warn_privileged_run() {
    [ "$(id -u)" = 0 ] || return 0
    log "warning: running as root — CodeMaster state (config.toml, daemon socket, skills) goes to $HOME_DIR"
    log "  the daemon is reachable only by the user who owns that home; run 'cm' as the same user,"
    log "  or install per-user without sudo: sh install.sh --prefix \"$HOME/.local/bin\""
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != root ]; then
        log "  installing for $SUDO_USER instead of root: re-run without sudo, or pass --home and --prefix of that user"
    fi
    return 0
}

warn_privileged_run
preflight_runtimes
if [ -n "$LOCAL_BIN" ]; then
    SRC_DIR=$LOCAL_BIN
elif [ "$FROM_SOURCE" = 1 ]; then
    install_from_source
else
    install_from_release
fi

pick_prefix
install_binaries
install_skills
export CODEMASTER_HOME="$HOME_DIR"

if [ "$SKIP_RUN" = 1 ]; then
    log "--no-run: skipping SurrealDB and daemon startup"
    pick_db_mode
    resolve_coordinates
    write_storage_config
    ask_embeddings_config
    expand_config_template
else
    start_surreal
    write_storage_config
    # The embeddings questions precede the daemon start on purpose: the
    # daemon reads [embeddings] at startup, so a channel enabled here is
    # live from the first index, not only after a restart.
    ask_embeddings_config
    expand_config_template
    log "starting daemon"
    # One call, no private wait loop. `cm daemon start` owns the bounded wait for
    # the first health answer (SPEC-4) and, if the daemon dies, reports the
    # reason it logged together with the exit-status family (SPEC-3). The loop
    # that used to be here existed because the CLI gave up after 5 s on a fresh
    # database; it retried a failure that had already been decided, and its
    # timeout could not agree with the configuration.
    "$PREFIX/cm" daemon start \
        || die "cm daemon start failed; the reason is printed above and recorded in $HOME_DIR/logs/daemon.log"
    "$PREFIX/cm" --json status || true
fi

cat <<EOF

CodeMaster installed. Next steps in a project directory:
  cd /path/to/repo
  cm init && cm index        # first full index
If the database already hosts several projects, index needs the target:
  cm index --project <UUID>  # UUID is printed by cm init
All configuration keys and defaults are inline in $HOME_DIR/config.toml;
  cm config explain          # prints what is actually in effect and from where

Anything unreachable? 'cm doctor' reads this machine — configuration, the
[storage] coordinates, the database port, the daemon and the binaries — and exits
non-zero only when something blocks work.

Register the MCP server in agent configs, e.g. opencode.json:
  "mcp": {
    "codemaster": {
      "type": "local",
      "command": ["$PREFIX/cm-mcp"],
      "enabled": true
    }
  }
EOF
