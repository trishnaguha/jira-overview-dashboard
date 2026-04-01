# JIRA Overview Dashboard

A CLI tool that queries JIRA live and generates both a **terminal dashboard** and an **HTML dashboard** for ANSTRAT, AAP, and ACA projects.

## Projects & Filters

| Project | Issue Types | Filter |
|---------|------------|--------|
| ANSTRAT | All types | Components (configurable) |
| AAP | Epics only | Components (configurable) |
| ACA | Epics only | Workstream: Networking Content |

## Requirements

- `curl`
- `jq`
- API token file at `~/claude-workspace/token`

## Usage

```bash
# Navigate to the project
cd jira-overview-dashboard

# Default components (portal, dev-tools) — outputs CLI + generates HTML
bash jira-dashboard-cli.sh

# Single component
bash jira-dashboard-cli.sh --component portal

# Multiple components (comma-separated)
bash jira-dashboard-cli.sh --component portal,dev-tools

# Any valid JIRA components
bash jira-dashboard-cli.sh --component portal,dev-tools,controller

# Show help
bash jira-dashboard-cli.sh --help
```


### Open the generated HTML dashboard

```bash
open file://<absolute path>/jira-overview-dashboard/jira-dashboard.html
```

## What happens when you run it

1. Queries JIRA live for ANSTRAT, AAP, and ACA projects
2. Prints a color-coded dashboard to the **terminal**
3. Generates **`jira-dashboard.html`** in the same directory (overwritten each run)
4. Prints the HTML output path at the bottom

## Files

| File | Description |
|------|-------------|
| `jira-dashboard-cli.sh` | Main script — runs queries, renders CLI output, generates HTML |
| `jira-dashboard.html` | Generated HTML dashboard (auto-created on each run) |
