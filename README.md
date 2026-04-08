# MoVP Plugins

MoVP gives your AI coding tools a control plane — adversarial code reviews, health scores, cost tracking, and recommendations. Install the plugin for your tool and connect to your MoVP backend.

Backend and CLI are available separately — contact us or check your MoVP account for access.

---

## Quick Install

### Any platform (recommended)

```
npx @movp/cli install
```

### Mac / Linux

```bash
curl -fsSL https://get.movp.dev/install.sh | sh
```

### Mac (Homebrew)

```bash
brew tap MostViableProduct/movp && brew install movp
```

### Windows (PowerShell)

```powershell
irm https://get.movp.dev/install.ps1 | iex
```

---

## Connect to your project

After installing plugins, run `init` inside each project you want to monitor:

### Claude Code

```bash
cd your-project
npx @movp/cli init
```

### Cursor

```bash
cd your-project
npx @movp/cli init --cursor
```

### Codex

```bash
cd your-project
npx @movp/cli init --codex
```

> **Homebrew users**: use `movp init`, `movp init --cursor`, or `movp init --codex` instead of `npx @movp/cli init`.

This sets up the MCP server connection and telemetry hooks. You'll be prompted to log in on first run.

---

## Load the plugin

### Claude Code (marketplace — recommended)

Register the MoVP marketplace once in `~/.claude/settings.json` (or in your project's `.claude/settings.json` for team rollout):

```json
{
  "extraKnownMarketplaces": {
    "movp": {
      "source": {
        "source": "github",
        "repo": "MostViableProduct/movp-plugins"
      }
    }
  },
  "enabledPlugins": {
    "movp@movp": true
  }
}
```

Then just run `claude` — no flags needed. To update after a new release:

```
/plugin marketplace update
```

**Name alignment:** the `extraKnownMarketplaces` key (`movp`), the marketplace `name`, and the `enabledPlugins` key (`movp@movp`) must all stay in sync.

### Claude Code (manual, one-off)

```bash
claude --plugin-dir ~/.movp/plugins/claude-plugin
```

> **Homebrew users**: `movp claude` instead of the `--plugin-dir` flag above.

### Cursor

```bash
cursor --plugin-dir ~/.movp/plugins/cursor-plugin
```

### Codex

```bash
codex --plugin-dir ~/.movp/plugins/codex-plugin
```

> **Homebrew users**: use `movp cursor` or `movp codex` instead of the `--plugin-dir` flags above.

---

## Verify installation

Confirm the plugin directories are present before loading:

**macOS / Linux**

```bash
ls ~/.movp/plugins/
```

**Windows**

```cmd
dir %USERPROFILE%\.movp\plugins
```

You should see `claude-plugin`, `codex-plugin`, and `cursor-plugin` directories. Homebrew installs to `$(brew --prefix)/share/movp/` instead.

---

## What you get

### Slash commands (Claude Code)

| Command | What it does |
|---------|-------------|
| `/movp:review` | Run an adversarial review of your latest artifact |
| `/movp:review-status` | Check current review status |
| `/movp:review-stop` | Stop a running review |
| `/movp:review-summarize` | Summarize completed review |
| `/movp:optimize` | Analyze review patterns, suggest rule improvements |
| `/movp:status` | Show MoVP connection and config status |

### Always-on behaviors (all platforms, via skills)

- Automatic adversarial reviews on plan files and multi-file code changes
- Project health scores at the start of each working session
- Cost tracking and budget awareness
- Constraint checks before significant architecture changes

---

## Prerequisites

- **Node.js 18+** — [nodejs.org](https://nodejs.org)
- **A MoVP backend** — cloud or self-hosted
- **One of:** Claude Code, Cursor 2.5+, or Codex

---

## Advanced

### MCP setup

Most users run `npx @movp/cli init` which writes MCP config automatically. The `.mcp.json.example` in each plugin directory is for reference only — copy it to `.mcp.json` and fill in your credentials if you prefer manual setup.

> **Never commit files containing real `WORKDESK_API_KEY` values.** The `.gitignore` in each plugin directory excludes `.mcp.json`.

### Avoiding duplicate MCP servers

`init` writes `mcpServers.movp` into `.claude/settings.json` (Claude Code), `.cursor/mcp.json` (Cursor), or `codex.yaml` (Codex). If you also create `.mcp.json` in the plugin root, you will have two `movp` server registrations. Use one mechanism — `init` for project setup (recommended) or plugin `.mcp.json` for standalone plugin installs — not both.

### Skills not firing?

Skills rely on the model matching their `description` field. If `movp-control-plane` doesn't activate at session start, copy the SKILL.md body into your project's always-on rules as a fallback:

- **Claude Code**: copy to `.claude/rules/movp-control-plane.md`
- **Cursor**: copy to `.cursor/rules/movp-control-plane.mdc`
- **Codex**: add to custom instructions

---

## Troubleshooting

**MCP not loading**
- Check the `node` path in your MCP config — it must be the absolute path to `dist/index.js`
- Verify `WORKDESK_SERVICE_URL`, `WORKDESK_TENANT`, and `WORKDESK_API_KEY` are set

**Duplicate server registrations**
- Use `init` OR plugin `.mcp.json`, not both (see above)

**Wrong `dist/index.js` path**
- Run `npx @movp/cli status` or inspect `.mcp.json.example` for the expected path shape

**Plugin commands not appearing**
- Verify `--plugin-dir` points to a plugin subdirectory (`claude-plugin/`), not the plugins repo root

---

## Compatibility

| Platform | Minimum version |
|----------|----------------|
| Claude Code | Plugin support required |
| Cursor | 2.5+ |
| Codex | Agent Skills support required |
| MCP server | Node.js 18+ + MoVP Workdesk backend |
