# frozen_string_literal: true

require "digest"

module Models
  # Proactive drift detector: scans the active +LlmModel+ catalog and reports
  # models whose entries are known to be incompatible with the currently
  # installed runner contracts. Surfaces the same facts that the dispatch-time
  # checks (Models::Select, Runners::ResolveTierModel) use to reject
  # candidates, but before a queue run wastes time discovering the rejection.
  #
  # This is structural detection only (ZFC): it surfaces the diff and leaves
  # the semantic judgment — whether to mark a model inactive, raise the
  # runner's CLI pin, or migrate to a different model — to the agent that
  # picks up the filed issue.
  #
  # Only HARD incompatibilities are reported (the runner contract returns
  # +supported: false+). "Unknown" outcomes — the runner has no static
  # contract for the model — are treated as permissive, matching how
  # Runners::ModelCompatibility behaves at runtime.
  class DetectContractDrift
    # Subscription / api_key auth modes. The detector checks each model
    # against the runner's contract under both auth modes so an api_key-only
    # model in the active catalog is also flagged for subscription runners.
    AUTH_MODES = %w[subscription api_key].freeze

    # Temporary suppression for models that remain globally valid in the
    # catalog but are known to be unavailable only on one auth path. Keep the
    # suppression local to contract-drift reporting rather than flipping the
    # row inactive, because +active+ gates all catalog consumers.
    SUPPRESSED_AUTH_MODE_GATED_FINDINGS = {
      "codex" => {
        "subscription" => %w[gpt-5.3-codex].freeze
      }.freeze
    }.freeze

    # Cap the number of findings per (provider, runner_key, auth_type) tuple
    # so a single misconfigured model does not balloon the issue body.
    MAX_FINDINGS_PER_GROUP = 50

    def self.call(...)
      new(...).call
    end

    def initialize(runner_keys: RunnerSupport.container_executable_runner_keys, auth_types: AUTH_MODES)
      @runner_keys = Array(runner_keys).map(&:to_s)
      @auth_types = Array(auth_types).map(&:to_s)
    end

    def call
      grouped = scan
      return Result.new(findings: [], runner_count: @runner_keys.size) if grouped.empty?

      Result.new(
        findings: grouped.map { |group, entries| build_finding(group, entries) },
        runner_count: @runner_keys.size
      )
    end

    private

    # Keys: [ provider, runner_key, auth_type ]
    # Values: Array<{ model_id, model_provider, incompatibility_type, reason, replacement_model_id }>
    def scan
      grouped = {}

      active_models = LlmModel.active
      active_models.find_each do |model|
        runner_keys_for_model(model).each do |runner_key|
          @auth_types.each do |auth_type|
            result = Runners::ModelCompatibility.call(
              runner_key: runner_key,
              model_id: model.model_id,
              auth_type: auth_type
            )
            next unless result.unsupported?
            next if suppressed_auth_mode_gated_finding?(runner_key:, auth_type:, model_id: model.model_id, result:)

            key = [ model.provider, runner_key, auth_type ]
            grouped[key] ||= []
            next if grouped[key].size >= MAX_FINDINGS_PER_GROUP

            grouped[key] << {
              model_id: model.model_id,
              model_provider: model.provider,
              incompatibility_type: result.incompatibility_type,
              reason: result.reason,
              replacement_model_id: result.replacement_model_id
            }
          end
        end
      end

      grouped
    end

    # The set of runner_keys that could actually pick up this model. Drift
    # only matters for pairings the runner would naturally consider — a
    # cross-provider match (an openai model on a claude runner) is
    # selection's job to reject, not contract drift. Returns:
    #   - the runner(s) that own the model's provider (e.g. codex for openai)
    #   - all direct-outbound runners, because those are configured per-model
    #     and their compatibility is set by the user's tier_model_ids / config
    def runner_keys_for_model(model)
      standard_runners = Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER
        .select { |_, provider| provider == model.provider }
        .keys

      matches = []
      matches.concat(standard_runners & @runner_keys)
      matches.concat(@runner_keys & Runners::DefaultTierModelIds::DIRECT_OUTBOUND_RUNNER_KEYS)
      matches.uniq
    end

    def suppressed_auth_mode_gated_finding?(runner_key:, auth_type:, model_id:, result:)
      return false unless result.incompatibility_type == :auth_mode_gated_for_model

      suppressed_model_ids = SUPPRESSED_AUTH_MODE_GATED_FINDINGS
        .fetch(runner_key, {})
        .fetch(auth_type, [])
      suppressed_model_ids.include?(model_id)
    end

    def build_finding(group, entries)
      provider, runner_key, auth_type = group
      {
        provider: provider,
        runner_key: runner_key,
        auth_type: auth_type,
        models: entries.map { |entry| entry[:model_id] }.sort,
        sample_reasons: entries.first(3).map { |entry| entry[:reason] }.compact,
        incompatibility_types: entries.map { |entry| entry[:incompatibility_type] }.uniq.compact,
        replacements: entries.filter_map { |entry| entry[:replacement_model_id] }.uniq.sort
      }
    end

    # Immutable view of the contract-drift findings.
    class Result
      attr_reader :findings, :runner_count

      def initialize(findings:, runner_count:)
        @findings = findings
        @runner_count = runner_count
      end

      def drift?
        @findings.any?
      end

      def total_affected_models
        @findings.sum { |finding| finding[:models].size }
      end

      # Stable digest of the finding set, used to dedup the filed issue.
      def fingerprint
        tokens = @findings.flat_map do |finding|
          replacements_token = finding[:replacements].join(",")
          type_tokens = finding[:incompatibility_types].sort.map(&:to_s).join(",")
          finding[:models].map do |id|
            "drift:#{finding[:runner_key]}:#{finding[:auth_type]}:#{id}:#{type_tokens}:#{replacements_token}"
          end
        end
        Digest::SHA256.hexdigest(tokens.sort.join("|"))
      end

      def to_h
        { findings: @findings, runner_count: @runner_count }
      end
    end
  end
end
