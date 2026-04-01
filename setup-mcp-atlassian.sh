#!/usr/bin/env bash
# setup-mcp-atlassian.sh
# Installs mcp-atlassian, configures mcp.json, and creates a token file
# from a user-provided credentials file.
#
# Usage:
#   bash setup-mcp-atlassian.sh                          # reads jira-credentials.txt
#   bash setup-mcp-atlassian.sh my-credentials.txt       # reads from custom file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDS_FILE="${1:-${SCRIPT_DIR}/jira-credentials.txt}"
MCP_JSON="${SCRIPT_DIR}/mcp.json"
TOKEN_FILE="${SCRIPT_DIR}/token"

# ── Validate credentials file ────────────────────────────────────────
if [[ ! -f "$CREDS_FILE" ]]; then
  echo "Error: Credentials file not found: $CREDS_FILE" >&2
  echo "" >&2
  echo "Create a file with the following format:" >&2
  echo "  JIRA_URL=https://your-domain.atlassian.net" >&2
  echo "  JIRA_EMAIL=your-email@example.com" >&2
  echo "  JIRA_API_TOKEN=your-jira-api-token-here" >&2
  echo "" >&2
  echo "See jira-credentials.txt.example for a template." >&2
  exit 1
fi

# ── Parse credentials ────────────────────────────────────────────────
JIRA_URL=""
JIRA_EMAIL=""
JIRA_API_TOKEN=""

while IFS='=' read -r key value; do
  # Skip empty lines and comments
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  key=$(echo "$key" | xargs)
  value=$(echo "$value" | xargs)
  case "$key" in
    JIRA_URL)       JIRA_URL="$value" ;;
    JIRA_EMAIL)     JIRA_EMAIL="$value" ;;
    JIRA_API_TOKEN) JIRA_API_TOKEN="$value" ;;
  esac
done < "$CREDS_FILE"

# Validate required fields
missing=""
[[ -z "$JIRA_URL" ]]       && missing+="  JIRA_URL\n"
[[ -z "$JIRA_EMAIL" ]]     && missing+="  JIRA_EMAIL\n"
[[ -z "$JIRA_API_TOKEN" ]] && missing+="  JIRA_API_TOKEN\n"

if [[ -n "$missing" ]]; then
  echo "Error: Missing required fields in $CREDS_FILE:" >&2
  echo -e "$missing" >&2
  exit 1
fi

echo "Credentials loaded from: $CREDS_FILE"
echo "  JIRA_URL:   $JIRA_URL"
echo "  JIRA_EMAIL: $JIRA_EMAIL"
echo "  Token:      ****${JIRA_API_TOKEN: -4}"

# ── Install mcp-atlassian ────────────────────────────────────────────
echo ""
echo "Installing mcp-atlassian..."

if command -v pip3 &>/dev/null; then
  pip3 install mcp-atlassian
elif command -v pip &>/dev/null; then
  pip install mcp-atlassian
else
  echo "Error: pip not found. Please install Python 3 and pip first." >&2
  exit 1
fi

echo "mcp-atlassian installed successfully."

# ── Create token file ────────────────────────────────────────────────
echo ""
echo "Creating token file at: $TOKEN_FILE"
echo "$JIRA_API_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
echo "Token file created (permissions: 600)."

# ── Generate mcp.json ────────────────────────────────────────────────
echo ""
echo "Generating MCP configuration at: $MCP_JSON"

cat > "$MCP_JSON" <<MCPEOF
{
  "mcpServers": {
    "mcp-atlassian": {
      "command": "python3",
      "args": ["-m", "mcp_atlassian"],
      "env": {
        "JIRA_URL": "${JIRA_URL}",
        "JIRA_EMAIL": "${JIRA_EMAIL}",
        "JIRA_API_TOKEN": "${JIRA_API_TOKEN}"
      }
    }
  }
}
MCPEOF

echo "MCP configuration written."

# ── Update jira-dashboard-cli.sh to use local token ──────────────────
DASHBOARD_SCRIPT="${SCRIPT_DIR}/jira-dashboard-cli.sh"
if [[ -f "$DASHBOARD_SCRIPT" ]]; then
  # Check if the script still points to the old token path
  if grep -q 'TOKEN_FILE="\${HOME}/claude-workspace/token"' "$DASHBOARD_SCRIPT"; then
    sed -i.bak 's|TOKEN_FILE="\${HOME}/claude-workspace/token"|TOKEN_FILE="\${SCRIPT_DIR}/token"|' "$DASHBOARD_SCRIPT"
    rm -f "${DASHBOARD_SCRIPT}.bak"
    echo "Updated jira-dashboard-cli.sh to use local token file."
  fi

  # Update JIRA_DOMAIN if it differs
  CURRENT_DOMAIN=$(grep '^JIRA_DOMAIN=' "$DASHBOARD_SCRIPT" | head -1 | cut -d'"' -f2)
  if [[ "$CURRENT_DOMAIN" != "$JIRA_URL" ]]; then
    sed -i.bak "s|JIRA_DOMAIN=\"${CURRENT_DOMAIN}\"|JIRA_DOMAIN=\"${JIRA_URL}\"|" "$DASHBOARD_SCRIPT"
    rm -f "${DASHBOARD_SCRIPT}.bak"
    echo "Updated JIRA_DOMAIN to: $JIRA_URL"
  fi

  # Update JIRA_EMAIL if it differs
  CURRENT_EMAIL=$(grep '^JIRA_EMAIL=' "$DASHBOARD_SCRIPT" | head -1 | cut -d'"' -f2)
  if [[ "$CURRENT_EMAIL" != "$JIRA_EMAIL" ]]; then
    sed -i.bak "s|JIRA_EMAIL=\"${CURRENT_EMAIL}\"|JIRA_EMAIL=\"${JIRA_EMAIL}\"|" "$DASHBOARD_SCRIPT"
    rm -f "${DASHBOARD_SCRIPT}.bak"
    echo "Updated JIRA_EMAIL to: $JIRA_EMAIL"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "======================================"
echo "  Setup complete!"
echo "======================================"
echo ""
echo "Files created:"
echo "  - ${TOKEN_FILE}   (API token)"
echo "  - ${MCP_JSON}     (MCP server config)"
echo ""
echo "Next steps:"
echo "  1. Run the dashboard:"
echo "     bash jira-dashboard-cli.sh"
echo ""
echo "  2. To use with Claude Code MCP:"
echo "     claude --mcp-config ${MCP_JSON}"
echo ""
echo "  3. To verify mcp-atlassian is working:"
echo "     python3 -m mcp_atlassian --help"
echo ""
