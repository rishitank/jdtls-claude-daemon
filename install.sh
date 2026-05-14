#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${JDTLS_DAEMON_INSTALL_DIR:-$HOME/.local/bin}"

echo "Installing jdtls-claude-daemon to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cp bin/jdtls "$INSTALL_DIR/jdtls"
cp bin/jdtls-daemon "$INSTALL_DIR/jdtls-daemon"
chmod +x "$INSTALL_DIR/jdtls" "$INSTALL_DIR/jdtls-daemon"

echo ""
echo "Installed successfully."
echo ""
echo "Make sure $INSTALL_DIR appears on your PATH *before* the real jdtls binary:"
echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
echo ""
echo "Verify:"
echo "  which jdtls   # must print $INSTALL_DIR/jdtls"
echo ""
echo "If using the Piebald-AI/claude-code-lsps plugin, update jdtls/.lsp.json:"
echo '  "startupTimeout": 300000, "maxRestarts": 100'
echo ""
echo "For SIGUSR1 cache-clear:"
echo "  kill -USR1 \$(cat /tmp/jdtls-daemon.pid)"
