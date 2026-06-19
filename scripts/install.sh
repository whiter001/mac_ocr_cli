#!/usr/bin/env bash
# install.sh — Install mac_ocr_cli binary and its Claude Code skill globally.
#
# Default: download the latest universal release from GitHub, install binary to
# $PREFIX/bin (default ~/.local/bin), install skill to $SKILL_DIR (default
# ~/.claude/skills/mac-ocr-cli).
#
# Usage:
#   ./scripts/install.sh                 # install latest release
#   ./scripts/install.sh --from-source   # build from this checkout
#   ./scripts/install.sh --prefix /usr/local
#   ./scripts/install.sh --uninstall
#   ./scripts/install.sh --version v0.1.0
#
# Environment overrides:
#   PREFIX     install root for the binary   (default: $HOME/.local)
#   SKILL_DIR  install dir for the skill     (default: $HOME/.claude/skills/mac-ocr-cli)
#   REPO       GitHub owner/repo             (default: whiter001/mac_ocr_cli)

set -euo pipefail

REPO="${REPO:-whiter001/mac_ocr_cli}"
PREFIX="${PREFIX:-$HOME/.local}"
SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/mac-ocr-cli}"
BIN_NAME="mac_ocr_cli"
ARTIFACT_NAME="mac_ocr_cli-darwin-universal"
GITHUB_API="https://api.github.com"
GITHUB_DL="https://github.com"

# ---- helpers ---------------------------------------------------------------

log()  { printf '\033[34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

usage() {
    cat <<EOF
install.sh — install mac_ocr_cli binary and its Claude Code skill

Usage:
  $0 [options]

Options:
  --prefix <dir>     Install root for the binary (default: \$HOME/.local)
  --skill-dir <dir>  Install dir for the skill (default: \$HOME/.claude/skills/mac-ocr-cli)
  --from-source      Build from the current checkout instead of downloading a release
                     (must be run from the repo root)
  --version <tag>    Install a specific release tag (default: latest)
  --uninstall        Remove the binary and skill
  -h, --help         Show this help

Environment:
  REPO=<owner/repo>  Override the GitHub repository (default: $REPO)
EOF
}

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# ---- platform check --------------------------------------------------------

check_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die "mac_ocr_cli is macOS-only (you're on $(uname -s))"
    fi
    local macos_major
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    if [[ "${macos_major}" -lt 13 ]]; then
        die "macOS 13+ required (you're on $(sw_vers -productVersion))"
    fi
}

# ---- uninstall -------------------------------------------------------------

uninstall() {
    log "Removing $PREFIX/bin/$BIN_NAME"
    rm -f "$PREFIX/bin/$BIN_NAME"
    rmdir "$PREFIX/bin" 2>/dev/null || true
    rmdir "$PREFIX"      2>/dev/null || true
    log "Removing $SKILL_DIR"
    rm -rf "$SKILL_DIR"
    rmdir "$(dirname "$SKILL_DIR")" 2>/dev/null || true
    log "Done. (PATH entry for $PREFIX/bin is left in place — remove manually if desired.)"
    exit 0
}

# ---- install binary --------------------------------------------------------

install_binary_from_release() {
    local tag="$1"
    local download_url
    if [[ "$tag" == "latest" ]]; then
        log "Resolving latest release from $REPO"
        download_url="$(
            curl -fsSL "$GITHUB_API/repos/$REPO/releases/latest" \
                | grep -oE "https://[^\"]*${ARTIFACT_NAME}\.zip" \
                | head -1
        )"
        [[ -n "$download_url" ]] || die "could not find $ARTIFACT_NAME.zip in latest release"
    else
        download_url="$GITHUB_DL/$REPO/releases/download/$tag/${ARTIFACT_NAME}.zip"
    fi
    log "Downloading $(basename "$download_url")"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fL --retry 3 -o "$tmpdir/release.zip" "$download_url"
    log "Extracting"
    require unzip
    unzip -q "$tmpdir/release.zip" -d "$tmpdir"
    [[ -f "$tmpdir/$ARTIFACT_NAME/$BIN_NAME" ]] || die "extracted archive is missing the binary"
    mkdir -p "$PREFIX/bin"
    install -m 0755 "$tmpdir/$ARTIFACT_NAME/$BIN_NAME" "$PREFIX/bin/$BIN_NAME"
    log "Installed binary to $PREFIX/bin/$BIN_NAME"
}

install_binary_from_source() {
    log "Building from source (release configuration)"
    require swift
    local script_dir repo_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    [[ -f "$repo_root/Package.swift" ]] || die "Package.swift not found at $repo_root (run --from-source from the repo root)"

    (
        cd "$repo_root"
        swift build -c release --arch arm64
        swift build -c release --arch x86_64
        local arm_bin x86_bin out_dir
        arm_bin="$(swift build -c release --arch arm64 --show-bin-path)/$BIN_NAME"
        x86_bin="$(swift build -c release --arch x86_64 --show-bin-path)/$BIN_NAME"
        out_dir="$(mktemp -d)"
        lipo -create -output "$out_dir/$BIN_NAME" "$arm_bin" "$x86_bin"
        mkdir -p "$PREFIX/bin"
        install -m 0755 "$out_dir/$BIN_NAME" "$PREFIX/bin/$BIN_NAME"
        rm -rf "$out_dir"
    )
    log "Installed binary to $PREFIX/bin/$BIN_NAME"
}

# ---- install skill ---------------------------------------------------------

install_skill() {
    local script_dir repo_root skill_src
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    skill_src="$repo_root/skill/SKILL.md"
    [[ -f "$skill_src" ]] || die "skill source not found: $skill_src (run from the repo root or use --from-source-aware installer)"

    log "Installing skill to $SKILL_DIR"
    mkdir -p "$SKILL_DIR"
    install -m 0644 "$skill_src" "$SKILL_DIR/SKILL.md"
    log "Installed skill to $SKILL_DIR/SKILL.md"
}

# ---- verify ----------------------------------------------------------------

verify_install() {
    local bin_path="$PREFIX/bin/$BIN_NAME"
    log "Verifying $bin_path"
    "$bin_path" --version || die "binary failed --version"
    "$bin_path" --help    >/dev/null || die "binary failed --help"

    if [[ -d "$SKILL_DIR" && -f "$SKILL_DIR/SKILL.md" ]]; then
        log "Skill is in place at $SKILL_DIR"
    else
        warn "Skill not found at $SKILL_DIR — Claude Code won't pick it up"
    fi

    if ! command -v "$BIN_NAME" >/dev/null 2>&1; then
        cat <<EOF

\033[33m注意:\033[0m $PREFIX/bin is not on your PATH.

Add this to your shell config (~/.zshrc or ~/.bashrc):

    export PATH="\$HOME/.local/bin:\$PATH"

Then restart the shell (or 'source ~/.zshrc').
EOF
    fi
}

# ---- main ------------------------------------------------------------------

main() {
    local from_source=0
    local tag="latest"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)     PREFIX="$2"; shift 2 ;;
            --skill-dir)  SKILL_DIR="$2"; shift 2 ;;
            --from-source) from_source=1; shift ;;
            --version)    tag="$2"; shift 2 ;;
            --uninstall)  uninstall ;;
            -h|--help)    usage; exit 0 ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
    done

    check_macos

    require curl
    require install
    require mkdir

    if [[ "$from_source" -eq 1 ]]; then
        install_binary_from_source
    else
        install_binary_from_release "$tag"
    fi
    install_skill
    verify_install
}

main "$@"
