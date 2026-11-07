#!/bin/zsh
# Puts every Terminal window back on the original profile and removes terminal_background.
set -u
BIN="${HOME:?}/.local/bin/terminal_background"
[[ -x "$BIN" ]] && "$BIN" reset
rm -f "$BIN"
rm -rf "${HOME:?}/Library/Application Support/terminal_background"
echo "Removed terminal_background."
