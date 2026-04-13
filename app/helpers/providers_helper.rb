# frozen_string_literal: true

module ProvidersHelper
  PROVIDER_AUTH_INSTRUCTION_COPY = {
    "claude" => {
      summary: "Use one of these:",
      items: [
        "Set <code>ANTHROPIC_API_KEY</code> on the <code>web</code> service for proxy-based auth.",
        "Or sign in with <code>claude login</code> and make <code>~/.claude/.credentials.json</code> visible to Paid.",
        "If Claude creds live elsewhere, set <code>CLAUDE_CONFIG_DIR</code>."
      ]
    },
    "codex" => {
      summary: "Use one of these:",
      items: [
        "Set <code>OPENAI_API_KEY</code> on the <code>web</code> service for proxy-based auth.",
        "Or sign in with the Codex CLI and make <code>~/.codex/auth.json</code> visible to Paid.",
        "If Codex creds live elsewhere, set <code>CODEX_CONFIG_DIR</code> or <code>CODEX_HOME</code>."
      ]
    },
    "gemini" => {
      summary: "Use one of these:",
      items: [
        "Set <code>GOOGLE_API_KEY</code> on the <code>web</code> service for proxy-based auth.",
        "Or run <code>gemini auth login</code> and make <code>~/.gemini/oauth_creds.json</code> visible to Paid.",
        "If Gemini creds live elsewhere, set <code>GEMINI_CONFIG_DIR</code>."
      ]
    },
    "opencode" => {
      summary: "Choose the auth path that matches the provider entry:",
      items: [
        "Set <code>OPENAI_API_KEY</code> on the <code>web</code> service for Paid-managed proxy auth.",
        "API-key OpenCode entries can also use a saved Provider API Key plus a provider-level model ID for direct outbound calls.",
        "OpenCode does not currently have a separate local subscription-auth mount in Paid."
      ]
    },
    "kilocode" => {
      summary: "KiloCode currently relies on provider-level API-key configuration in Paid:",
      items: [
        "Create the provider with a compatible Provider API Key for the selected upstream API provider.",
        "Set a KiloCode model ID on the provider record so Paid can generate the CLI config it mounts into the agent container.",
        "KiloCode does not currently have a separate local subscription-auth mount in Paid."
      ]
    },
    "copilot" => {
      summary: "GitHub Copilot currently uses subscription auth in Paid:",
      items: [
        "Sign in with the GitHub Copilot CLI and make <code>~/.config/github-copilot/hosts.json</code> visible to Paid.",
        "If Copilot creds live elsewhere, set <code>COPILOT_CONFIG_DIR</code>.",
        "Restart the <code>web</code> and <code>worker</code> services after changing credential mounts."
      ]
    }
  }.freeze

  def provider_auth_instruction_blocks
    Provider.supported_provider_keys.map { |provider_key| provider_auth_instruction_block(provider_key) }
  end

  private

  def provider_auth_instruction_block(provider_key)
    copy = PROVIDER_AUTH_INSTRUCTION_COPY[provider_key]
    return copy.merge(provider_key: provider_key, title: Provider.display_name(provider_key), fallback: false) if copy

    Rails.logger.warn(message: "providers.auth_instructions.missing_copy", provider_key: provider_key)

    {
      provider_key: provider_key,
      title: Provider.display_name(provider_key),
      summary: "Use the auth mode configured on the provider entry:",
      items: [
        "Subscription entries rely on the provider CLI's local login state being visible inside the agent container.",
        "API-key entries rely on a compatible Paid Provider API Key or proxy-backed service configuration.",
        "Provider-specific setup notes are not available yet, so this generic checklist is shown instead of hiding the provider."
      ],
      fallback: true
    }
  end
end
