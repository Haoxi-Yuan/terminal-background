#!/bin/zsh
# Builds terminal_background and installs it to ~/.local/bin.
set -euo pipefail
cd "${0:A:h}"

if ! command -v swiftc >/dev/null; then
    echo "The Swift compiler is missing. Install Apple's Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

BIN="$HOME/.local/bin"
mkdir -p build "$BIN"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -framework AppKit \
    Sources/main.swift -o build/terminal_background
cp build/terminal_background "$BIN/terminal_background"
echo "Installed $BIN/terminal_background"

# Make sure new shells find the command.
if [[ ":$PATH:" != *":$BIN:"* ]] && ! grep -qs '\.local/bin' "$HOME/.zshrc"; then
    print -r -- 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
    echo "Added ~/.local/bin to PATH in ~/.zshrc. Open a new Terminal window (or run: source ~/.zshrc)."
fi
