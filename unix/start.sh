#!/usr/bin/env bash
# start.sh - Entry point for SlipStream Auto Connector (Linux/macOS)
# Just run: ./start.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Make scripts executable if they aren't
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
chmod +x "$SCRIPT_DIR/slipstream-connect.sh" 2>/dev/null
chmod +x "$SCRIPT_DIR/lib/"*.sh 2>/dev/null
chmod +x "$PROJECT_ROOT/slipstream-client" 2>/dev/null

# Run the main script, pass through all arguments
exec bash "$SCRIPT_DIR/slipstream-connect.sh" "$@"
