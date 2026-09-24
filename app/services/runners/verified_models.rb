# frozen_string_literal: true

module Runners
  # Durable execution evidence, scoped more narrowly than catalog availability.
  # The fingerprint excludes CLI versions: upgrades must not erase a working
  # replacement. Explicit runner/auth/model configuration changes do invalidate it.
  # @spec RUNNER-FALLBACK-008
  class VerifiedModels
    KEY = "verified_models"

    def initialize(runner)
      @runner = runner
      @context = fingerprint
    end

    def model_for(tier, project: nil, goal: nil)
      model_id = evidence.dig("tiers", tier.to_s, "model_id")
      model_id if model_id.present? && permitted?(model_id, project: project, goal: goal)
    end

    def rejected?(model_id)
      Array(evidence["rejected"]).include?(model_id)
    end

    def permitted?(model_id, project: nil, goal: nil)
      model = LlmModel.find_by(model_id: model_id)
      return false if model&.operator_active_override == false

      provider = DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key]
      return false if provider.blank? || (model && model.provider != provider)
      return true unless project

      preferences = project.model_preferences
      required = preferences["required_model_id"]
      project.llm_provider_allowed?(provider) &&
        !Array(preferences["excluded_model_ids"]).include?(model_id) &&
        (required.blank? || required == model_id) && within_tier_bounds?(model, preferences, goal)
    end

    def reject!(model_id)
      mutate do |data|
        data["rejected"] = (Array(data["rejected"]) + [ model_id ]).uniq.last(100)
        data["tiers"] = (data["tiers"] || {}).reject { |_, value| value["model_id"] == model_id }
        data["generation"] = SecureRandom.uuid
      end
    end

    def remember!(tier:, model_id:, generation:, project: nil, goal: nil)
      mutate do |data|
        next false unless data["generation"] == generation
        next false unless permitted?(model_id, project: project&.reload, goal: goal)

        data["tiers"] ||= {}
        data["tiers"][tier.to_s] = { "model_id" => model_id, "verified_at" => Time.current.iso8601 }
        data["rejected"] = Array(data["rejected"]) - [ model_id ]
        true
      end
    end

    private

    attr_reader :runner, :context

    def within_tier_bounds?(model, preferences, goal)
      tiers = LlmModel::TIERS
      minimum = preferences.dig("goal_min_tiers", goal) || preferences["quality_recovery_min_tier"]
      maximum = preferences["max_tier"]
      return true if minimum.blank? && maximum.blank?

      index = tiers.index(model&.tier)
      index && (minimum.blank? || index >= (tiers.index(minimum) || 0)) &&
        (maximum.blank? || index <= (tiers.index(maximum) || tiers.length))
    end

    def fingerprint
      values = runner.attributes.slice("id", "runner_key", "auth_type", "provider_api_key_id",
        "integration_credential_id", "config", "tier_model_ids", "tier_models")
      Digest::SHA256.hexdigest(canonical(values).to_json)
    end

    def canonical(value)
      case value
      when Hash then value.sort.to_h.transform_values { |entry| canonical(entry) }
      when Array then value.map { |entry| canonical(entry) }
      else value
      end
    end

    def evidence
      return {} unless runner.persisted?

      data = runner.user.runner_states.find_by(runner_name: runner.state_key)&.metadata&.fetch(KEY, {}) || {}
      data["context"] == context ? data : {}
    end

    def mutate
      return false unless runner.persisted?

      runner.with_lock do
        next false unless fingerprint == context

        state = runner.user.runner_states.find_or_create_by!(runner_name: runner.state_key)
        state.with_lock do
          data = state.metadata.fetch(KEY, {}).deep_dup
          data = { "context" => context } unless data["context"] == context
          result = yield data
          next false if result == false

          state.update!(metadata: state.metadata.merge(KEY => data))
          result
        end
      end
    end
  end
end
