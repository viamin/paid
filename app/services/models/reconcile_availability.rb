# frozen_string_literal: true

module Models
  # Persists runner/auth/account-scoped availability evidence, separate from
  # LlmModel#active, so Models::SeedKnownModels never has to choose between
  # a stale catalog snapshot and evidence a model actually works.
  #
  # .refresh! is the periodic path (called from ModelsSyncJob after seeding):
  # it sweeps active catalog models for a runner/auth context, bounded and
  # deduplicated by ModelAvailabilityCheck's freshness window.
  #
  # .record_rejection! is the reactive path for a structured runtime
  # rejection: it records the rejection, bounds retry_count, and surfaces a
  # Models::PolicyEligibleReplacement candidate for a single preflight retry.
  # It never deactivates the LlmModel globally and never touches auth.
  #
  # @spec MODEL-AVAILABILITY-004
  # @spec MODEL-AVAILABILITY-005
  class ReconcileAvailability
    MAX_RETRIES = 3

    # The runner/auth contexts ModelsSyncJob reconciles periodically.
    # Codex is checked under both auth types because subscription and
    # api_key entitlements diverge (the concrete case behind #3945); other
    # standard runners are only ever dispatched with the default auth type.
    STANDARD_CONTEXTS = Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER.keys.flat_map { |runner_key|
      auth_types = runner_key == "codex" ? Runner::AUTH_TYPES : [ Runners::DefaultTierModelIds::DEFAULT_AUTH_TYPE ]
      auth_types.map { |auth_type| [ runner_key, auth_type ] }
    }.freeze

    def self.refresh!(...) = new.refresh!(...)
    def self.record_rejection!(...) = new.record_rejection!(...)

    # @spec MODEL-AVAILABILITY-004
    def self.refresh_known_contexts!
      STANDARD_CONTEXTS.to_h do |runner_key, auth_type|
        checked = new.refresh!(runner_key: runner_key, auth_type: auth_type)
        [ "#{runner_key}:#{auth_type}", checked.size ]
      end
    end

    def refresh!(runner_key:, auth_type:, account: nil)
      provider = Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner_key.to_s]
      return [] if provider.blank?

      LlmModel.active.by_provider(provider).find_each.filter_map do |model|
        next if fresh_check?(model, runner_key, auth_type, account)

        record_compatibility(model, runner_key, auth_type, account)
      end
    end

    def record_rejection!(llm_model:, runner_key:, auth_type:, reason:, account: nil, incompatibility_type: nil, attempted_model_id: nil)
      check = find_or_initialize_check(llm_model, runner_key, auth_type, account)
      excluded = excluded_model_ids(runner_key, auth_type, account) << llm_model.model_id
      replacement = PolicyEligibleReplacement.call(rejected_model: llm_model, excluded_model_ids: excluded)

      check.assign_attributes(
        status: "unavailable",
        source: "runtime_rejection",
        reason: reason,
        incompatibility_type: incompatibility_type&.to_s,
        replacement_model_id: replacement&.model_id,
        attempted_model_id: attempted_model_id || llm_model.model_id,
        retry_count: [ check.retry_count.to_i + 1, MAX_RETRIES ].min,
        checked_at: Time.current,
        expires_at: ModelAvailabilityCheck::DEFAULT_TTL.from_now
      )
      check.save!
      check
    end

    private

    def fresh_check?(model, runner_key, auth_type, account)
      existing = ModelAvailabilityCheck.find_by(
        llm_model: model, runner_key: runner_key.to_s, auth_type: auth_type.to_s, account: account
      )
      existing.present? && !existing.stale?
    end

    def record_compatibility(model, runner_key, auth_type, account)
      compat = Runners::ModelCompatibility.call(
        runner_key: runner_key, model_id: model.model_id, auth_type: auth_type, llm_model: model
      )
      return if compat.unknown?

      check = find_or_initialize_check(model, runner_key, auth_type, account)
      check.assign_attributes(
        status: compat.supported? ? "available" : "unavailable",
        source: "agent_harness_compat",
        reason: compat.reason,
        incompatibility_type: compat.incompatibility_type&.to_s,
        replacement_model_id: compat.replacement_model_id,
        attempted_model_id: model.model_id,
        retry_count: compat.supported? ? 0 : check.retry_count.to_i,
        checked_at: Time.current,
        expires_at: ModelAvailabilityCheck::DEFAULT_TTL.from_now
      )
      check.save!
      check
    end

    def find_or_initialize_check(model, runner_key, auth_type, account)
      ModelAvailabilityCheck.find_or_initialize_by(
        llm_model: model, runner_key: runner_key.to_s, auth_type: auth_type.to_s, account: account
      )
    end

    def excluded_model_ids(runner_key, auth_type, account)
      ModelAvailabilityCheck.unavailable
        .where(runner_key: runner_key.to_s, auth_type: auth_type.to_s, account: account)
        .joins(:llm_model)
        .pluck("llm_models.model_id")
        .to_set
    end
  end
end
