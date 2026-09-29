#!/bin/sh
set -e

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
linux*) OS='linux' ;;
darwin*) OS='macos' ;;
*) echo "Unsupported OS: $OS" && exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
x86_64) ARCH='x86_64' ;;
arm64 | aarch64) ARCH='aarch64' ;;
i386 | i686) ARCH='x86' ;;
*) echo "Unsupported architecture: $ARCH" && exit 1 ;;
esac

if [ "$OS" = "macos" ] && [ "$ARCH" = "x86" ]; then
  echo "macOS 32-bit is unsupported" && exit 1
fi

REPOS_URL="https://api.github.com/repos/Satheeshsk369/zigup/releases"
BINARY_NAME="zigup-${ARCH}-${OS}"

RELEASES_JSON=$(curl -sSfL "$REPOS_URL")
if [ -z "$RELEASES_JSON" ]; then
  echo "Failed to fetch releases list from GitHub API" && exit 1
fi

TAG=""

IFS='
'
for row in $(echo "$RELEASES_JSON" | grep -E '"tag_name":|browser_download_url'); do
  if echo "$row" | grep -q '"tag_name":'; then
    CURRENT_TAG=$(echo "$row" | sed -E 's/.*"tag_name":[[:space:]]*"([^"]*)".*/\1/')
  elif echo "$row" | grep -q "$BINARY_NAME"; then
    TAG="$CURRENT_TAG"
    break
  fi
done
unset IFS

if [ -z "$TAG" ]; then
  echo "Failed to find a release tag with compiled binary: $BINARY_NAME" && exit 1
fi

DOWNLOAD_URL="https://github.com/Satheeshsk369/zigup/releases/download/${TAG}/${BINARY_NAME}"
BIN_DIR="${XDG_DATA_HOME:-$HOME/.local}/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zig"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zigup"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zigup"

mkdir -p "$BIN_DIR" "$DATA_DIR" "$CONFIG_DIR" "$CACHE_DIR"
echo "Downloading zigup for ${OS}-${ARCH} (tag ${TAG})"
curl -sSfL "$DOWNLOAD_URL" -o "$BIN_DIR/zigup"
chmod +x "$BIN_DIR/zigup"

if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
  if ! command -v termux-elf-cleaner >/dev/null 2>&1; then
    pkg install -y termux-elf-cleaner >/dev/null 2>&1 || true
  fi

  if command -v termux-elf-cleaner >/dev/null 2>&1; then
    termux-elf-cleaner "$BIN_DIR/zigup" >/dev/null 2>&1 || true
  fi

  BYTE16=$(od -An -j16 -N1 -tu1 "$BIN_DIR/zigup" 2>/dev/null | tr -d ' ' || true)
  if [ "$BYTE16" = "2" ]; then
    printf '\x03' | dd of="$BIN_DIR/zigup" bs=1 seek=16 count=1 conv=notrunc status=none 2>/dev/null || true
  fi
fi

echo "Successfully installed zigup to $BIN_DIR/zigup"
