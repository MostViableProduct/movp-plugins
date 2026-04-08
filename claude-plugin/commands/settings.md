---
description: "Open the MoVP settings page in your browser (subscription, API keys, usage)"
---

Open the MoVP settings page for the current tenant.

1. Read the MoVP configuration by accessing the `movp://movp/config` MCP resource to get `settings_url`.
   - `settings_url` is pre-constructed by the MCP server from `MOVP_FRONTEND_URL` + tenant slug.
   - It is the authoritative URL — do not construct it yourself.

2. Validate `settings_url` before opening:
   - It must start with `https://` or `http://localhost` or `http://127.0.0.1`.
   - If it does not match one of these patterns, do **not** open it. Instead print:
     `Refusing to open settings_url — unexpected scheme or host.`

3. Open the validated URL in the user's default browser using the Bash tool:
   - macOS: `open "<settings_url>"`
   - Linux: `xdg-open "<settings_url>"`

4. Print a confirmation: `Opened MoVP settings: <settings_url>`

If `settings_url` is not present in the config response, print:
```
Could not determine your MoVP settings URL.
Visit https://host.mostviableproduct.com and navigate to Settings from your workspace.
```
