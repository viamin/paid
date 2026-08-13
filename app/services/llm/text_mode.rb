# frozen_string_literal: true

module Llm
  # Decides whether a pure-text LLM call should use agent-harness's
  # HTTP-based text mode (+mode: :text+) or the default CLI transport.
  #
  # Text mode bypasses the +claude+ CLI entirely, eliminating host-process
  # +cwd+ / git-state sensitivity and avoiding CLAUDE.md memory loading.
  # That closes the class of bug where a PR body silently inherits context
  # from whatever directory the Rails host happens to be in.
  #
  # Billing/auth constraint: agent-harness's text transport requires a
  # direct Anthropic API key. Using it with OAuth/subscription credentials
  # would silently shift billing from subscription-backed CLI usage to
  # API-metered HTTP usage, so this router only opts in when
  # +ANTHROPIC_API_KEY+ is explicitly configured in the host environment.
  # Without an API key, callers fall back to the CLI transport and billing
  # routing is preserved unchanged.
  #
  # Kill switch: set +PAID_LLM_TEXT_MODE_DISABLED=1+ to force all
  # +Llm::*+ services back onto the CLI path without a code change. Useful
  # during a staged rollout if regressions appear on the HTTP path.
  module TextMode
    KILL_SWITCH_ENV = "PAID_LLM_TEXT_MODE_DISABLED"
    API_KEY_ENV = "ANTHROPIC_API_KEY"
    TRUTHY_VALUES = %w[1 true yes on].freeze

    module_function

    # Options to merge into +AgentHarness.send_message+. Returns
    # +{mode: :text}+ when HTTP transport is eligible, otherwise +{}+ so
    # the call falls back to the default CLI transport.
    #
    # @return [Hash]
    def options
      enabled? ? { mode: :text } : {}
    end

    # @return [Boolean] whether text mode should be used for this process.
    def enabled?
      return false if kill_switch_enabled?

      api_key_present?
    end

    def kill_switch_enabled?
      TRUTHY_VALUES.include?(ENV[KILL_SWITCH_ENV].to_s.strip.downcase)
    end

    def api_key_present?
      key = ENV[API_KEY_ENV]
      !key.nil? && !key.strip.empty?
    end
  end
end
