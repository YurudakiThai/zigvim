#!/bin/bash
# Fetch Neovim runtime for zigvim
# Downloads the official Neovim runtime and extracts lua modules

set -e

NVIM_VERSION="${1:-0.12.6}"
RUNTIME_DIR="runtime"
LUA_DIR="$RUNTIME_DIR/lua"

echo "Fetching Neovim v$NVIM_VERSION runtime..."

# Detect OS
OS="$(uname -s)"
case "$OS" in
  Darwin)
    PLATFORM="macos"
    ARCH="$(uname -m)"
    if [ "$ARCH" = "arm64" ]; then
      ARCH="arm64"
    else
      ARCH="x86_64"
    fi
    ;;
  Linux)
    PLATFORM="linux"
    ARCH="$(uname -m)"
    if [ "$ARCH" = "x86_64" ]; then
      ARCH="x86_64"
    elif [ "$ARCH" = "aarch64" ]; then
      ARCH="arm64"
    fi
    ;;
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

# Create runtime directory
mkdir -p "$LUA_DIR"

# Download Neovim release
URL="https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}/nvim-${PLATFORM}-${ARCH}.tar.gz"
TMP_FILE="/tmp/nvim-${NVIM_VERSION}.tar.gz"

echo "Downloading from $URL..."
if command -v curl &> /dev/null; then
  curl -L -o "$TMP_FILE" "$URL"
elif command -v wget &> /dev/null; then
  wget -O "$TMP_FILE" "$URL"
else
  echo "Error: curl or wget required"
  exit 1
fi

echo "Extracting runtime/lua..."
tar -xzf "$TMP_FILE" -C "$RUNTIME_DIR" --strip-components=4 "nvim-${PLATFORM}-${ARCH}/share/nvim/runtime/lua"

# tree-sitter: Neovim's bundled queries and parsers (runtime/parser is on 'runtimepath')
echo "Extracting runtime/queries and parsers..."
tar -xzf "$TMP_FILE" -C "$RUNTIME_DIR" --strip-components=4 "nvim-${PLATFORM}-${ARCH}/share/nvim/runtime/queries"
tar -xzf "$TMP_FILE" -C "$RUNTIME_DIR" --strip-components=3 "nvim-${PLATFORM}-${ARCH}/lib/nvim/parser"

# Lua ftplugin/indent files (zigvim sources only the .lua ones; lua/markdown/help/query start tree-sitter)
FT_TMP="$(mktemp -d)"
tar -xzf "$TMP_FILE" -C "$FT_TMP" --strip-components=4 "nvim-${PLATFORM}-${ARCH}/share/nvim/runtime/ftplugin" "nvim-${PLATFORM}-${ARCH}/share/nvim/runtime/indent"
for sub in ftplugin indent; do
  mkdir -p "$RUNTIME_DIR/$sub"
  cp "$FT_TMP/$sub"/*.lua "$RUNTIME_DIR/$sub/"
done
rm -rf "$FT_TMP"

rm "$TMP_FILE"

echo "✅ Neovim v$NVIM_VERSION runtime installed to $LUA_DIR"
echo "Files: $(find $LUA_DIR -type f | wc -l)"
echo "Size: $(du -sh $LUA_DIR | cut -f1)"
