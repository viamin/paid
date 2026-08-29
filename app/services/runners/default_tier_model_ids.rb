# frozen_string_literal: true

module Runners
  class DefaultTierModelIds
    RUNNER_KEY_TO_MODEL_PROVIDER = {
      "claude" => "anthropic",
      "cursor" => "anthropic",
      "codex" => "openai",
      "gemini" => "google"
    }.freeze

    DIRECT_OUTBOUND_RUNNER_KEYS = %w[kilocode opencode pi omp].freeze

    # Compatibility gate applied when callers have no concrete auth context
    # (e.g. the admin form seeding a brand-new runner). Callers on the dispatch
    # path (Runners::ResolveTierModel) pass the runner's actual auth_type so
    # auth-mode-gated models are filtered out before the default is dispatched.
    DEFAULT_AUTH_TYPE = "api_key"

    def self.call(runner_key:, auth_type: DEFAULT_AUTH_TYPE)
      new(runner_key: runner_key, auth_type: auth_type).call
    end

    def initialize(runner_key:, auth_type: DEFAULT_AUTH_TYPE)
      @runner_key = runner_key.to_s
      @auth_type = auth_type.to_s.presence || DEFAULT_AUTH_TYPE
    end

    def call
      model_provider = RUNNER_KEY_TO_MODEL_PROVIDER[@runner_key]
      return {} if model_provider.blank? && !DIRECT_OUTBOUND_RUNNER_KEYS.include?(@runner_key)

      if model_provider
        tier_defaults_for_standard_provider(model_provider)
      else
        {}
      end
    end

    private

    attr_reader :runner_key, :auth_type

    def tier_defaults_for_standard_provider(model_provider) # @spec RUNNER-MODEL-OPTIONS-006
      model_entries = ModelOptions.call(
        runner_key: runner_key,
        api_provider: model_provider,
        auth_type: auth_type
      ).select(&:model?).filter_map(&:model)

      LlmModel::TIERS.each_with_object({}) do |tier, mapping|
        model = model_entries.select { |m| m.tier == tier }.max_by { |m| m.capability_score.to_f }
        mapping[tier] = model.model_id if model
      end
    end
  end
end
