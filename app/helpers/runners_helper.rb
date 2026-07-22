# frozen_string_literal: true

module RunnersHelper
  RUNNER_AUTH_INSTRUCTION_COPY = {
    "claude" => {
      summary: "Use one of these:",
      items: [
        "Preferred: capture a managed Claude credential in Paid with the browser-completed Claude login flow; Paid will use that managed credential by default when it is active.",
        "Set <code>ANTHROPIC_API_KEY</code> on the <code>web</code> service for proxy-based auth when you want an API-key runner instead.",
        "Host-mounted <code>~/.claude/.credentials.json</code> remains a local-only fallback. If Claude creds live elsewhere, set <code>CLAUDE_CONFIG_DIR</code>."
      ]
    },
    "codex" => {
      summary: "Use one of these:",
      items: [
        "Set <code>OPENAI_API_KEY</code> on the <code>web</code> service for proxy-based auth.",
        "Host-mounted Codex subscription auth is local-only today: sign in with the Codex CLI and make <code>~/.codex/auth.json</code> visible to Paid on a host-path-capable backend.",
        "Remote-safe managed Codex subscription auth is still tracked separately in follow-up issue <code>#2962</code>. If Codex creds live elsewhere, set <code>CODEX_CONFIG_DIR</code> or <code>CODEX_HOME</code>."
      ]
    },
    "gemini" => {
      summary: "Use one of these:",
      items: [
        "Set <code>GOOGLE_API_KEY</code> on the <code>web</code> service for proxy-based auth.",
        "Host-mounted Gemini subscription auth is local-only today: run <code>gemini auth login</code> and make <code>~/.gemini/oauth_creds.json</code> visible to Paid on a host-path-capable backend.",
        "Remote-safe managed Gemini subscription auth is still tracked in follow-up issue <code>#2964</code>. If Gemini creds live elsewhere, set <code>GEMINI_CONFIG_DIR</code>."
      ]
    },
    "opencode" => {
      summary: "Choose the auth path that matches the runner entry:",
      items: [
        "Set <code>OPENAI_API_KEY</code> on the <code>web</code> service for Paid-managed proxy auth.",
        "API-key OpenCode entries can also use a saved Provider API Key plus a runner-level model ID for direct outbound calls.",
        "OpenCode does not currently have a separate local subscription-auth mount in Paid."
      ]
    },
    "kilocode" => {
      summary: "KiloCode currently relies on runner-level API-key configuration in Paid:",
      items: [
        "Create the runner with a compatible Provider API Key for the selected upstream API provider.",
        "Set a KiloCode model ID on the runner record so Paid can generate the CLI config it mounts into the agent container.",
        "KiloCode does not currently have a separate local subscription-auth mount in Paid."
      ]
    },
    "copilot" => {
      summary: "GitHub Copilot currently uses subscription auth in Paid:",
      items: [
        "Host-mounted Copilot subscription auth is local-only today: sign in with the GitHub Copilot CLI and make <code>~/.copilot/config.json</code> visible to Paid on a host-path-capable backend.",
        "Remote-safe managed Copilot subscription auth is still tracked in follow-up issue <code>#2964</code>. If Copilot creds live elsewhere, set <code>COPILOT_HOME</code> (or Paid's legacy <code>COPILOT_CONFIG_DIR</code> override).",
        "Restart the <code>web</code> and <code>worker</code> services after changing credential mounts."
      ]
    },
    "pi" => {
      summary: "Pi API-key auth is supported in Paid today:",
      items: [
        "API-key entries use a saved Provider API Key plus a runner-level Pi API Provider selection such as DeepSeek, OpenAI, or Anthropic.",
        "Paid writes a request-scoped <code>~/.pi/agent/auth.json</code> inside the agent container so Pi uses the selected key deterministically.",
        "Optional model IDs are passed through as <code>pi --model ...</code>; if left blank, Pi uses its default or previously selected model."
      ]
    }
  }.freeze

  def runner_auth_instruction_blocks
    Runner.supported_runner_keys.map { |runner_key| runner_auth_instruction_block(runner_key) }
  end

  def runner_usage_stats_for(runner)
    return unless @usage_stats

    stats = @usage_stats[runner.runner_key]
    stats ||= @usage_stats[runner.routing_key]
    stats
  end

  def format_token_count(count)
    if count >= 1_000_000
      "#{(count / 1_000_000.0).round(1)}M"
    elsif count >= 1_000
      "#{(count / 1_000.0).round(1)}k"
    else
      count.to_s
    end
  end

  private

  def runner_auth_instruction_block(runner_key)
    copy = RUNNER_AUTH_INSTRUCTION_COPY[runner_key]
    return copy.merge(runner_key: runner_key, title: Runner.display_name(runner_key), fallback: false) if copy

    {
      runner_key: runner_key,
      title: Runner.display_name(runner_key),
      summary: "Use the auth mode configured on the runner entry:",
      items: [
        "Subscription entries rely on the runner CLI's local login state being visible inside the agent container.",
        "API-key entries rely on a compatible Paid Provider API Key or proxy-backed service configuration.",
        "Runner-specific setup notes are not available yet, so this generic checklist is shown instead of hiding the runner."
      ],
      fallback: true
    }
  end
end
