#!/bin/bash
# Smoke test: Hub MCP configurator registers mcp_servers.hub with SSE + Bearer.
# Runs the full configure-hub-mcp.test.sh suite.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${HERE}/configure-hub-mcp.test.sh"
