class Movp < Formula
  desc "MoVP control plane plugins for AI coding tools"
  homepage "https://github.com/MostViableProduct/movp-plugins"
  url "https://github.com/MostViableProduct/movp-plugins/archive/v1.3.2.tar.gz"
  sha256 "fe0ad3530be577e322b9fb80931e66ffba96f2814b91198730d55aa01c37e29e"
  license "MIT"

  depends_on "node@18"

  def install
    (share/"movp/claude-plugin").install Dir["claude-plugin/*"]
    (share/"movp/codex-plugin").install Dir["codex-plugin/*"]
    (share/"movp/cursor-plugin").install Dir["cursor-plugin/*"]

    # Install a `movp` helper that runs init and launches tools with --plugin-dir
    (bin/"movp").write <<~EOS
      #!/bin/bash
      set -e

      CLAUDE_PLUGIN="#{share}/movp/claude-plugin"
      CURSOR_PLUGIN="#{share}/movp/cursor-plugin"
      CODEX_PLUGIN="#{share}/movp/codex-plugin"

      cmd="${1:-help}"
      case "$cmd" in
        init)
          shift
          case "${1:-}" in
            --cursor)
              npx @movp/cli init --cursor --no-rules
              echo
              echo "MoVP ready. Launch with: movp cursor"
              ;;
            --codex)
              npx @movp/cli init --codex
              echo
              echo "MoVP ready. Launch with: movp codex"
              ;;
            *)
              npx @movp/cli init --no-rules
              echo
              echo "MoVP ready. Launch with: movp claude"
              ;;
          esac
          ;;
        claude) shift; exec claude --plugin-dir "$CLAUDE_PLUGIN" "$@" ;;
        cursor) shift; exec cursor --plugin-dir "$CURSOR_PLUGIN" "$@" ;;
        codex)  shift; exec codex  --plugin-dir "$CODEX_PLUGIN"  "$@" ;;
        *)
          echo "Usage: movp <command>"
          echo ""
          echo "  movp init              Set up MoVP in the current project (Claude Code)"
          echo "  movp init --cursor     Set up MoVP in the current project (Cursor)"
          echo "  movp init --codex      Set up MoVP in the current project (Codex)"
          echo ""
          echo "  movp claude [args...]  Launch Claude Code with MoVP"
          echo "  movp cursor [args...]  Launch Cursor with MoVP"
          echo "  movp codex  [args...]  Launch Codex with MoVP"
          ;;
      esac
    EOS
    (bin/"movp").chmod 0755
  end

  def caveats
    <<~EOS
      To set up MoVP in your project:

        cd your-project
        movp init            # Claude Code
        movp init --cursor   # Cursor
        movp init --codex    # Codex

      Then launch with MoVP loaded:

        movp claude
        movp cursor
        movp codex

      Troubleshooting:
        If Claude Code shows "[MoVP] MCP tools not registered" on session start,
        re-run `movp init` inside the project — this regenerates ./.mcp.json,
        which the session probe reads. Run /movp:doctor inside Claude Code to
        diagnose further.

        Claude Code users: `init` works with or without the `claude` CLI on
        PATH. Without it, user-level registration in ~/.claude.json is skipped
        but ./.mcp.json alone is sufficient for the session probe.

      Full docs: https://github.com/MostViableProduct/movp-plugins
    EOS
  end

  test do
    assert_predicate share/"movp/claude-plugin/.claude-plugin/plugin.json", :exist?
    assert_predicate share/"movp/codex-plugin/.codex-plugin/plugin.json", :exist?
    assert_predicate share/"movp/cursor-plugin/.cursor-plugin/plugin.json", :exist?
    assert_predicate bin/"movp", :executable?
  end
end
