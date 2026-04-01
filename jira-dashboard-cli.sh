#!/usr/bin/env bash
# JIRA Dashboard — ANSTRAT, AAP & ACA (In Progress)
# Queries JIRA API live and renders a formatted CLI dashboard.
#
# Usage:
#   bash jira-dashboard-cli.sh                                          # defaults: portal,dev-tools
#   bash jira-dashboard-cli.sh --component portal                       # single component
#   bash jira-dashboard-cli.sh --component portal,dev-tools             # multiple components
#   bash jira-dashboard-cli.sh --component portal,dev-tools,controller  # any valid components
#
# Requirements: curl, jq
# Token file:   ~/claude-workspace/token

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
JIRA_DOMAIN="https://redhat.atlassian.net"
JIRA_EMAIL="tguha@redhat.com"
TOKEN_FILE="${HOME}/claude-workspace/token"
ACA_WORKSTREAM="Networking Content"
DEFAULT_COMPONENTS="portal,dev-tools"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML_OUTPUT="${SCRIPT_DIR}/jira-dashboard.html"

# ── Read token ──────────────────────────────────────────────────────
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "Error: Token file not found at $TOKEN_FILE" >&2
  exit 1
fi
JIRA_TOKEN=$(head -1 "$TOKEN_FILE" | tr -d '[:space:]')

# ── Parse arguments ────────────────────────────────────────────────
COMP_INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --component)
      if [[ -n "${2:-}" ]]; then
        COMP_INPUT="$2"
        shift 2
      else
        echo "Error: --component requires a value (e.g., --component portal,dev-tools)" >&2
        exit 1
      fi
      ;;
    -h|--help)
      echo "Usage: bash jira-dashboard-cli.sh [--component comp1,comp2,...]"
      echo ""
      echo "Options:"
      echo "  --component   Comma-separated list of JIRA components (default: portal,dev-tools)"
      echo "  -h, --help    Show this help message"
      echo ""
      echo "Examples:"
      echo "  bash jira-dashboard-cli.sh                                # defaults: portal,dev-tools"
      echo "  bash jira-dashboard-cli.sh --component portal             # single component"
      echo "  bash jira-dashboard-cli.sh --component portal,dev-tools   # multiple components"
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'. Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# Use default if no --component provided
COMP_INPUT="${COMP_INPUT:-$DEFAULT_COMPONENTS}"

# Split comma-separated components into JQL format
IFS=',' read -ra COMPONENTS <<< "$COMP_INPUT"
COMP_JQL=""
for comp in "${COMPONENTS[@]}"; do
  comp=$(echo "$comp" | xargs)  # trim whitespace
  [[ -n "$COMP_JQL" ]] && COMP_JQL+=", "
  COMP_JQL+="\"${comp}\""
done
COMP_DISPLAY=$(IFS=', '; echo "${COMPONENTS[*]}")

# ── Colors ──────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
RED='\033[91m'
ORANGE='\033[38;5;208m'
GREEN='\033[92m'
BLUE='\033[94m'
CYAN='\033[96m'
PURPLE='\033[95m'
WHITE='\033[97m'
GRAY='\033[37m'
TEAL='\033[38;5;43m'
BG_BLUE='\033[48;5;17m'

HLINE="${DIM}$(printf '%.0s─' {1..120})${RESET}"

# ── JIRA API helper (v3) ──────────────────────────────────────────
jira_search() {
  local jql="$1"
  local fields="$2"
  local max_results="${3:-50}"

  curl -s \
    -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    "${JIRA_DOMAIN}/rest/api/3/search/jql" \
    -d "$(jq -n \
      --arg jql "$jql" \
      --argjson fields "$fields" \
      --argjson max "$max_results" \
      '{jql: $jql, fields: $fields, maxResults: $max}'
    )"
}

# ── Render a project section ───────────────────────────────────────
render_project() {
  local project_key="$1"
  local json_data="$2"
  local filter_label="$3"
  local group_col_header="$4"
  local group_col_fallback="${5:-}"  # shown when components field is empty

  local total
  total=$(echo "$json_data" | jq '.issues | length')

  if [[ "$total" -eq 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${WHITE}${project_key}${RESET}  ${BG_BLUE}${BLUE}${BOLD} 0 issues ${RESET}  ${DIM}${filter_label}${RESET}"
    echo -e "  ${DIM}No matching issues found.${RESET}"
    echo ""
    echo -e "$HLINE"
    return
  fi

  echo ""
  echo -e "  ${BOLD}${WHITE}${project_key}${RESET}  ${BG_BLUE}${BLUE}${BOLD} ${total} issues ${RESET}  ${DIM}${filter_label}${RESET}"
  echo ""

  # Get priorities in display order
  local priorities
  priorities=$(echo "$json_data" | jq -r '
    ["Blocker","Critical","Major","Normal","Minor","Trivial","Undefined"] as $order |
    [.issues[].fields.priority.name // "Undefined"] | unique |
    map(. as $p | {name: $p, idx: ([$order | to_entries[] | select(.value == $p) | .key] | first // 999)}) |
    sort_by(.idx) | .[].name
  ')

  for priority in $priorities; do
    local count
    count=$(echo "$json_data" | jq --arg p "$priority" '
      [.issues[] | select((.fields.priority.name // "Undefined") == $p)] | length')

    # Priority color
    local pcolor="$GRAY"
    case "$priority" in
      Blocker|Critical) pcolor="$RED" ;;
      Major)            pcolor="$ORANGE" ;;
      Normal)           pcolor="$GREEN" ;;
      Minor|Trivial)    pcolor="$CYAN" ;;
    esac

    local priority_upper
    priority_upper=$(echo "$priority" | tr '[:lower:]' '[:upper:]')
    echo -e "  ${pcolor}${BOLD}▌ ${priority_upper} (${count})${RESET}"
    printf "  ${DIM}%-16s %-58s %-12s %-22s %-18s %s${RESET}\n" "KEY" "SUMMARY" "TYPE" "ASSIGNEE" "$group_col_header" "UPDATED"
    echo -e "  $HLINE"

    echo "$json_data" | jq -r --arg p "$priority" '
      .issues[]
      | select((.fields.priority.name // "Undefined") == $p)
      | [
          .key,
          (.fields.summary | if length > 56 then .[:53] + "..." else . end),
          .fields.issuetype.name,
          (.fields.assignee.displayName // "Unassigned"),
          (([.fields.components[]?.name] | join(",")) | if . == "" then "__EMPTY__" else . end),
          (.fields.updated | split("T")[0] | split("-") |
            (["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
              [.[1] | tonumber - 1]) + " " + (.[2] | tonumber | tostring))
        ] | @tsv
    ' | while IFS=$'\t' read -r key summary itype assignee components updated; do
      # Use fallback label if components is empty
      if [[ "$components" == "__EMPTY__" ]]; then
        if [[ -n "$group_col_fallback" ]]; then
          components="$group_col_fallback"
        else
          components="-"
        fi
      fi

      local tcolor="$BLUE"
      case "$itype" in
        Bug)        tcolor="$RED" ;;
        Story)      tcolor="$GREEN" ;;
        Task)       tcolor="$ORANGE" ;;
        Feature|Initiative|Outcome) tcolor="$PURPLE" ;;
        Spike)      tcolor="$CYAN" ;;
      esac

      local ccolor="$TEAL"
      if [[ "$components" == *"portal"* ]]; then ccolor="$PURPLE"
      elif [[ "$components" == *"dev-tools"* ]]; then ccolor="$CYAN"
      fi

      local acolor=""
      [[ "$assignee" == "Unassigned" ]] && acolor="$RED"

      printf "  ${BLUE}%-16s${RESET} %-58s ${tcolor}%-12s${RESET} ${acolor}%-22s${RESET} ${ccolor}%-18s${RESET} ${DIM}%s${RESET}\n" \
        "$key" "$summary" "$itype" "$assignee" "$components" "$updated"
    done
    echo ""
  done
  echo -e "$HLINE"
}

# ── HTML project section generator ─────────────────────────────────
html_project_section() {
  local project_key="$1"
  local json_data="$2"
  local filter_label="$3"
  local col_header="$4"
  local col_fallback="${5:-}"

  local total
  total=$(echo "$json_data" | jq '.issues | length')

  local badge_label="issues"
  if [[ "$project_key" != "ANSTRAT" ]]; then badge_label="epics"; fi

  echo "  <div class=\"project-section\">"
  echo "    <div class=\"project-header\">"
  echo "      <h2>${project_key}</h2>"
  echo "      <span class=\"project-badge\">${total} ${badge_label}</span>"
  echo "      <span class=\"project-filter\">${filter_label}</span>"
  echo "    </div>"

  if [[ "$total" -eq 0 ]]; then
    echo "    <p class=\"empty-msg\">No matching issues found.</p>"
    echo "  </div>"
    return
  fi

  local priorities
  priorities=$(echo "$json_data" | jq -r '
    ["Blocker","Critical","Major","Normal","Minor","Trivial","Undefined"] as $order |
    [.issues[].fields.priority.name // "Undefined"] | unique |
    map(. as $p | {name: $p, idx: ([$order | to_entries[] | select(.value == $p) | .key] | first // 999)}) |
    sort_by(.idx) | .[].name
  ')

  for priority in $priorities; do
    local count
    count=$(echo "$json_data" | jq --arg p "$priority" \
      '[.issues[] | select((.fields.priority.name // "Undefined") == $p)] | length')

    local pcls
    pcls=$(echo "$priority" | tr '[:upper:]' '[:lower:]')

    echo "    <div class=\"priority-group\">"
    echo "      <span class=\"priority-label ${pcls}\">${priority} (${count})</span>"
    echo "      <table class=\"issue-table\">"
    echo "        <thead><tr><th>Key</th><th>Summary</th><th>Type</th><th>Assignee</th><th>${col_header}</th><th>Status</th><th>Updated</th></tr></thead>"
    echo "        <tbody>"

    echo "$json_data" | jq -r --arg p "$priority" --arg domain "$JIRA_DOMAIN" --arg fallback "$col_fallback" '
      .issues[]
      | select((.fields.priority.name // "Undefined") == $p)
      | {
          key: .key,
          summary: .fields.summary,
          type: .fields.issuetype.name,
          assignee: (.fields.assignee.displayName // "Unassigned"),
          components: (([.fields.components[]?.name] | join(",")) | if . == "" then $fallback else . end),
          updated: (.fields.updated | split("T")[0] | split("-") |
            (["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][.[1] | tonumber - 1]) + " " + (.[2] | tonumber | tostring))
        }
      | "          <tr>\n            <td class=\"issue-key\"><a href=\"\($domain)/browse/\(.key)\">\(.key)</a></td>\n            <td>\(.summary | gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") | gsub("\"";"&quot;"))</td>\n            <td><span class=\"type-badge type-\(.type | ascii_downcase)\">\(.type)</span></td>\n            <td class=\"assignee\(if .assignee == "Unassigned" then " unassigned" else "" end)\">\(.assignee)</td>\n            <td>\(.components | split(",") | map(. as $c | "<span class=\"component-tag \(if ($c | contains("portal")) then "component-portal" elif ($c | contains("dev-tools")) then "component-devtools" else "component-networking" end)\">\($c)</span>") | join(""))</td>\n            <td><span class=\"status-chip\">In Progress</span></td>\n            <td class=\"updated-date\">\(.updated)</td>\n          </tr>"
    '

    echo "        </tbody>"
    echo "      </table>"
    echo "    </div>"
  done

  echo "  </div>"
}

# ── Generate HTML dashboard ───────────────────────────────────────
generate_html() {
  local section_anstrat section_aap section_aca
  section_anstrat=$(html_project_section "ANSTRAT" "$DATA_ANSTRAT" "Components: ${COMP_DISPLAY}" "Components" "")
  section_aap=$(html_project_section "AAP" "$DATA_AAP" "Epics only | Components: ${COMP_DISPLAY}" "Components" "")
  section_aca=$(html_project_section "ACA" "$DATA_ACA" "Epics only | Workstream: ${ACA_WORKSTREAM}" "Workstream" "Networking Content")

  cat > "$HTML_OUTPUT" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>JIRA Dashboard — ANSTRAT, AAP & ACA</title>
  <style>
    :root {
      --bg: #0f1117;
      --surface: #1a1d27;
      --surface-hover: #222531;
      --border: #2a2d3a;
      --text: #e1e4ed;
      --text-muted: #8b8fa3;
      --accent: #6c8cff;
      --critical: #ff5c5c;
      --critical-bg: rgba(255, 92, 92, 0.12);
      --major: #ff9f43;
      --major-bg: rgba(255, 159, 67, 0.12);
      --normal: #54d9a8;
      --normal-bg: rgba(84, 217, 168, 0.12);
      --undefined: #94a3b8;
      --undefined-bg: rgba(148, 163, 184, 0.12);
      --blocker: #ef4444;
      --blocker-bg: rgba(239, 68, 68, 0.12);
      --minor: #60a5fa;
      --minor-bg: rgba(96, 165, 250, 0.12);
      --trivial: #a1a1aa;
      --trivial-bg: rgba(161, 161, 170, 0.12);
      --portal: #a78bfa;
      --portal-bg: rgba(167, 139, 250, 0.12);
      --devtools: #38bdf8;
      --devtools-bg: rgba(56, 189, 248, 0.12);
      --networking: #2dd4bf;
      --networking-bg: rgba(45, 212, 191, 0.12);
      --in-progress: #fbbf24;
      --in-progress-bg: rgba(251, 191, 36, 0.12);
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', sans-serif;
      background: var(--bg); color: var(--text); line-height: 1.6; padding: 2rem;
    }
    .header { text-align: center; margin-bottom: 2.5rem; padding-bottom: 1.5rem; border-bottom: 1px solid var(--border); }
    .header h1 { font-size: 1.8rem; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 0.25rem; }
    .header .subtitle { color: var(--text-muted); font-size: 0.9rem; }
    .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 1rem; margin-bottom: 2.5rem; }
    .stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 1.2rem; text-align: center; transition: transform 0.15s, border-color 0.15s; }
    .stat-card:hover { transform: translateY(-2px); border-color: var(--accent); }
    .stat-card .stat-value { font-size: 2rem; font-weight: 700; line-height: 1.2; }
    .stat-card .stat-label { font-size: 0.78rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.06em; margin-top: 0.2rem; }
    .project-section { margin-bottom: 2.5rem; }
    .project-header { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }
    .project-header h2 { font-size: 1.3rem; font-weight: 600; }
    .project-badge { background: var(--accent); color: #fff; font-size: 0.72rem; font-weight: 600; padding: 0.2rem 0.6rem; border-radius: 20px; }
    .project-filter { font-size: 0.75rem; color: var(--text-muted); font-style: italic; margin-left: auto; }
    .priority-group { margin-bottom: 1.5rem; }
    .priority-label { font-size: 0.8rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; padding: 0.3rem 0.7rem; border-radius: 6px; display: inline-block; margin-bottom: 0.75rem; }
    .priority-label.critical { color: var(--critical); background: var(--critical-bg); }
    .priority-label.major { color: var(--major); background: var(--major-bg); }
    .priority-label.normal { color: var(--normal); background: var(--normal-bg); }
    .priority-label.undefined { color: var(--undefined); background: var(--undefined-bg); }
    .priority-label.blocker { color: var(--blocker); background: var(--blocker-bg); }
    .priority-label.minor { color: var(--minor); background: var(--minor-bg); }
    .priority-label.trivial { color: var(--trivial); background: var(--trivial-bg); }
    .issue-table { width: 100%; border-collapse: collapse; margin-bottom: 0.5rem; }
    .issue-table thead th { text-align: left; font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-muted); padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); position: sticky; top: 0; background: var(--bg); }
    .issue-table tbody tr { border-bottom: 1px solid var(--border); transition: background 0.12s; }
    .issue-table tbody tr:hover { background: var(--surface-hover); }
    .issue-table td { padding: 0.7rem 0.8rem; font-size: 0.88rem; vertical-align: middle; }
    .issue-key { font-weight: 600; color: var(--accent); white-space: nowrap; font-family: 'SF Mono', 'Fira Code', monospace; font-size: 0.82rem; }
    .issue-key a { color: inherit; text-decoration: none; }
    .issue-key a:hover { text-decoration: underline; }
    .type-badge { font-size: 0.7rem; font-weight: 600; padding: 0.15rem 0.5rem; border-radius: 4px; white-space: nowrap; }
    .type-epic { color: #6c8cff; background: rgba(108,140,255,0.12); }
    .type-bug { color: #ff5c5c; background: rgba(255,92,92,0.12); }
    .type-story { color: #54d9a8; background: rgba(84,217,168,0.12); }
    .type-task { color: #ff9f43; background: rgba(255,159,67,0.12); }
    .type-feature { color: #a78bfa; background: rgba(167,139,250,0.12); }
    .type-spike { color: #38bdf8; background: rgba(56,189,248,0.12); }
    .type-initiative { color: #f472b6; background: rgba(244,114,182,0.12); }
    .type-outcome { color: #c084fc; background: rgba(192,132,252,0.12); }
    .component-tag { font-size: 0.7rem; padding: 0.15rem 0.45rem; border-radius: 4px; display: inline-block; margin: 0.1rem 0.15rem; font-weight: 500; }
    .component-portal { color: var(--portal); background: var(--portal-bg); }
    .component-devtools { color: var(--devtools); background: var(--devtools-bg); }
    .component-networking { color: var(--networking); background: var(--networking-bg); }
    .status-chip { font-size: 0.7rem; font-weight: 600; padding: 0.2rem 0.55rem; border-radius: 4px; color: var(--in-progress); background: var(--in-progress-bg); white-space: nowrap; }
    .assignee { white-space: nowrap; }
    .assignee.unassigned { color: var(--critical); font-style: italic; }
    .empty-msg { color: var(--text-muted); font-style: italic; padding: 1rem 0; }
    .footer { text-align: center; color: var(--text-muted); font-size: 0.78rem; margin-top: 2rem; padding-top: 1.5rem; border-top: 1px solid var(--border); }
    @media (max-width: 768px) {
      body { padding: 1rem; }
      .issue-table { font-size: 0.8rem; }
      .issue-table td, .issue-table th { padding: 0.5rem; }
      .stats-grid { grid-template-columns: repeat(2, 1fr); }
    }
  </style>
</head>
<body>
  <div class="header">
    <h1>ANSTRAT, AAP & ACA — In Progress Dashboard</h1>
    <div class="subtitle">Components: ${COMP_DISPLAY} &nbsp;|&nbsp; Generated: ${GENERATED}</div>
  </div>
  <div class="stats-grid">
    <div class="stat-card"><div class="stat-value" style="color:var(--accent)">${COUNT_TOTAL}</div><div class="stat-label">Total Issues</div></div>
    <div class="stat-card"><div class="stat-value" style="color:var(--critical)">${COUNT_CRITICAL}</div><div class="stat-label">Critical</div></div>
    <div class="stat-card"><div class="stat-value">${COUNT_ANSTRAT}</div><div class="stat-label">ANSTRAT</div></div>
    <div class="stat-card"><div class="stat-value">${COUNT_AAP}</div><div class="stat-label">AAP</div></div>
    <div class="stat-card"><div class="stat-value" style="color:var(--networking)">${COUNT_ACA}</div><div class="stat-label">ACA</div></div>
  </div>
${section_anstrat}
${section_aap}
${section_aca}
  <div class="footer">
    JIRA Dashboard &mdash; ANSTRAT, AAP &amp; ACA &mdash; Generated ${GENERATED} &mdash; Status: In Progress
  </div>
</body>
</html>
HTMLEOF
}

# ── Fetch data ─────────────────────────────────────────────────────
echo ""
echo -e "${DIM}  Querying JIRA (components: ${COMP_DISPLAY})...${RESET}"

FIELDS='["summary","status","assignee","priority","components","issuetype","updated"]'

DATA_ANSTRAT=$(jira_search \
  "project = ANSTRAT AND status = \"In Progress\" AND component in (${COMP_JQL})" \
  "$FIELDS")

DATA_AAP=$(jira_search \
  "project = AAP AND status = \"In Progress\" AND issuetype = Epic AND component in (${COMP_JQL})" \
  "$FIELDS")

DATA_ACA=$(jira_search \
  "project = ACA AND status = \"In Progress\" AND issuetype = Epic AND Workstream = \"${ACA_WORKSTREAM}\"" \
  "$FIELDS")

# ── Compute stats ──────────────────────────────────────────────────
COUNT_ANSTRAT=$(echo "$DATA_ANSTRAT" | jq '.issues | length')
COUNT_AAP=$(echo "$DATA_AAP" | jq '.issues | length')
COUNT_ACA=$(echo "$DATA_ACA" | jq '.issues | length')
COUNT_TOTAL=$((COUNT_ANSTRAT + COUNT_AAP + COUNT_ACA))

COUNT_CRITICAL=$(echo "$DATA_ANSTRAT" "$DATA_AAP" "$DATA_ACA" | jq -s '
  [.[].issues[]? | select(.fields.priority.name == "Critical")] | length')

GENERATED=$(date "+%B %d, %Y")

# ── Render header ──────────────────────────────────────────────────
echo -e '\033[1A\033[2K'
echo -e "${BOLD}${WHITE}  ╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${WHITE}  ║        ANSTRAT, AAP & ACA — In Progress Dashboard                   ║${RESET}"
printf "${BOLD}${WHITE}  ║        %-64s  ║${RESET}\n" "Components: ${COMP_DISPLAY} | ${GENERATED}"
echo -e "${BOLD}${WHITE}  ╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""

echo -e "  ${BOLD}${BLUE}${COUNT_TOTAL}${RESET} Total   ${BOLD}${RED}${COUNT_CRITICAL}${RESET} Critical   ${WHITE}${COUNT_ANSTRAT}${RESET} ANSTRAT   ${WHITE}${COUNT_AAP}${RESET} AAP   ${TEAL}${COUNT_ACA}${RESET} ACA"
echo ""
echo -e "$HLINE"

# ── Render projects ───────────────────────────────────────────────
render_project "ANSTRAT" "$DATA_ANSTRAT" "Components: ${COMP_DISPLAY}" "COMPONENTS"
render_project "AAP"     "$DATA_AAP"     "Epics only | Components: ${COMP_DISPLAY}" "COMPONENTS"
render_project "ACA"     "$DATA_ACA"     "Epics only | Workstream: ${ACA_WORKSTREAM}" "WORKSTREAM" "Networking Content"

# ── Generate HTML ─────────────────────────────────────────────────
generate_html
echo ""
echo -e "  ${GREEN}${BOLD}HTML dashboard written to:${RESET} ${HTML_OUTPUT}"
echo -e "  ${DIM}JIRA Dashboard — ANSTRAT, AAP & ACA — Generated ${GENERATED}${RESET}"
echo ""
