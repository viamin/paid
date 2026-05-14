# frozen_string_literal: true

module CoordinationPolicyEvolution
  class GenerateCandidates
    def self.call(...)
      new(...).call
    end

    def initialize(policy:, analysis:, options: {})
      @policy = policy.deep_symbolize_keys
      @analysis = analysis.deep_symbolize_keys
      @options = options.deep_symbolize_keys
    end

    def call
      mutations.map { |mutation| stamp_provenance(mutation) }
    end

    private

    attr_reader :policy, :analysis, :options

    def mutations
      @mutations ||= StrategyEvolution::Mutate.call(
        strategy: mutation_strategy,
        analysis: analysis,
        options: options
      )
    end

    def mutation_strategy
      {
        id: policy[:version_id] || policy[:id],
        strategy_type: policy[:policy_type],
        version: policy[:version],
        account_id: policy[:account_id],
        configuration: policy.fetch(:configuration)
      }
    end

    def stamp_provenance(mutation)
      StrategyEvolution::Mutate::Mutation.new(
        configuration: mutation.configuration,
        strategy: mutation.strategy,
        reasoning: mutation.reasoning,
        expected_improvement: mutation.expected_improvement,
        diff: mutation.diff,
        provenance: mutation.provenance.to_h.merge(
          "generated_by" => self.class.name,
          "policy_type" => policy[:policy_type],
          "policy_key" => policy[:policy_key],
          "source_policy_id" => policy[:id],
          "source_policy_version_id" => policy[:version_id],
          "sampled_decision_ids" => sampled_decision_ids,
          "prior_versions" => prior_version_summary,
          "measured_outcomes" => measured_outcomes
        )
      )
    end

    def sampled_decision_ids
      @sampled_decision_ids ||= [ *analysis.fetch(:sample_successes, []), *analysis.fetch(:sample_failures, []) ]
        .filter_map { |row| row[:id] || row["id"] }
        .uniq
    end

    def prior_version_summary
      Array(analysis[:prior_versions]).map do |version|
        row = version.respond_to?(:deep_symbolize_keys) ? version.deep_symbolize_keys : version
        {
          id: row[:id],
          version: row[:version],
          status: row[:status]
        }.compact
      end
    end

    def measured_outcomes
      analysis.fetch(:performance, {}).slice(
        :decision_count,
        :classified_decision_count,
        :success_count,
        :failure_count,
        :noop_count,
        :success_rate,
        :lookback_days,
        :decision_type_counts,
        :outcome_counts,
        :policy_source_counts,
        :average_task_count
      )
    end
  end
end
