# frozen_string_literal: true

module StrategyEvolution
  class GenerateCandidates
    def self.call(...)
      new(...).call
    end

    def initialize(strategy:, analysis:, options: {})
      @strategy = strategy.deep_symbolize_keys
      @analysis = analysis.deep_symbolize_keys
      @options = options.deep_symbolize_keys
    end

    def call
      mutations.map { |mutation| stamp_provenance(mutation) }
    end

    private

    attr_reader :strategy, :analysis, :options

    def mutations
      @mutations ||= StrategyEvolution::Mutate.call(
        strategy: strategy,
        analysis: analysis,
        options: options
      )
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
          active: row[:active]
        }.compact
      end
    end

    def measured_outcomes
      analysis.fetch(:performance, {}).slice(
        :decision_count,
        :min_decisions,
        :run_backed_decision_count,
        :success_count,
        :failure_count,
        :success_rate,
        :lookback_days,
        :decision_types,
        :actors,
        :run_statuses,
        :guardrail_violation_types
      )
    end
  end
end
