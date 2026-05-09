# frozen_string_literal: true

module Scaling
  class ResourceAllocator
    Allocation = Struct.new(
      :agent_count,
      :max_iterations,
      :parallelism_level,
      :source,
      :reason,
      :metrics,
      keyword_init: true
    )

    MIN_OBSERVATIONS_FOR_CONFIDENCE = 5
    STALE_THRESHOLD = 7.days
    MIN_SUCCESS_RATE_FOR_LEARNING = 0.3
    DIMINISHING_RETURNS_THRESHOLD = 0.05

    attr_reader :inputs, :observations, :experiment_summaries

    def initialize(inputs:, observations: [], experiment_summaries: [])
      @inputs = inputs
      @observations = observations
      @experiment_summaries = experiment_summaries
    end

    def self.call(...)
      new(...).call
    end

    def call
      if observations_fresh_and_sufficient?
        allocate_from_observations
      elsif experiment_summaries_usable?
        allocate_from_experiments
      else
        allocate_fallback
      end
    end

    private

    def allocate_from_observations
      return allocate_fallback if grouped.empty?

      best_value = find_optimal_agent_count(grouped)
      iterations = recommend_iterations(grouped, best_value)
      parallelism = recommend_parallelism(grouped, best_value)

      build_allocation(
        agent_count: clamp_agents(best_value),
        max_iterations: iterations,
        parallelism_level: parallelism,
        source: :observations,
        reason: observation_reason(grouped, best_value)
      )
    end

    def allocate_from_experiments
      best_summary = usable_experiment_summaries.max_by do |summary|
        [
          summary_value(summary, :success_rate, default: 0.0),
          -summary_value(summary, :avg_duration_seconds, default: Float::INFINITY)
        ]
      end
      return allocate_fallback unless best_summary

      value = summary_value(best_summary, :assigned_value) || summary_value(best_summary, :value)
      return allocate_fallback unless value

      agent_count = clamp_agents(value)
      build_allocation(
        agent_count: agent_count,
        max_iterations: 3,
        parallelism_level: parallelism_cap(agent_count),
        source: :experiment,
        reason: "experiment leading value=#{value} success_rate=#{format_rate(summary_value(best_summary, :success_rate, default: 0.0))}"
      )
    end

    def allocate_fallback
      conservative_agents = conservative_agent_count
      build_allocation(
        agent_count: conservative_agents,
        max_iterations: 3,
        parallelism_level: parallelism_cap(conservative_agents),
        source: :fallback,
        reason: fallback_reason
      )
    end

    def observations_fresh_and_sufficient?
      return false if observations.size < MIN_OBSERVATIONS_FOR_CONFIDENCE

      latest = observations.max_by(&:created_at)
      return false unless latest

      latest.created_at > STALE_THRESHOLD.ago
    end

    def experiment_summaries_usable?
      usable_experiment_summaries.any?
    end

    def group_by_agent_count
      observations
        .select { |obs| obs.agent_count_launched.to_i.positive? }
        .group_by { |obs| obs.agent_count_launched.to_i }
        .transform_values { |group| compute_group_stats(group) }
        .select { |_value, stats| stats[:count] >= 2 }
    end

    def compute_group_stats(group)
      success_rate = group.count(&:success).to_f / group.size
      avg_duration = group.sum { |obs| obs.duration_seconds.to_i }.to_f / group.size
      avg_cost = group.sum(&:total_cost_cents).to_f / group.size
      avg_iterations = group.sum { |obs| obs.total_iterations.to_i }.to_f / group.size

      {
        count: group.size,
        success_rate: success_rate,
        avg_duration_seconds: avg_duration,
        avg_cost_cents: avg_cost,
        avg_iterations: avg_iterations,
        observations: group
      }
    end

    def find_optimal_agent_count(grouped)
      sorted_values = grouped.keys.sort
      return sorted_values.first if sorted_values.size == 1

      scored = sorted_values.map do |value|
        stats = grouped[value]
        score = compute_allocation_score(stats, value, sorted_values)
        { value: value, score: score }
      end

      best = scored.max_by { |entry| entry[:score] }
      best[:value]
    end

    def compute_allocation_score(stats, value, sorted_values)
      success_weight = 0.5
      cost_weight = 0.3
      duration_weight = 0.2

      max_cost = sorted_values.map { |v| grouped[v][:avg_cost_cents] }.max.to_f
      max_duration = sorted_values.map { |v| grouped[v][:avg_duration_seconds] }.max.to_f

      cost_efficiency = max_cost.positive? ? 1.0 - (stats[:avg_cost_cents] / max_cost) : 0.5
      duration_efficiency = max_duration.positive? ? 1.0 - (stats[:avg_duration_seconds] / max_duration) : 0.5

      diminishing_penalty = compute_diminishing_penalty(value, sorted_values)

      raw_score = (stats[:success_rate] * success_weight) +
                  (cost_efficiency * cost_weight) +
                  (duration_efficiency * duration_weight) -
                  diminishing_penalty

      [ raw_score, 0.0 ].max
    end

    def compute_diminishing_penalty(value, sorted_values)
      return 0.0 if sorted_values.size < 2
      return 0.0 unless sorted_values.include?(value)

      idx = sorted_values.index(value)
      return 0.0 if idx.zero?

      prev_value = sorted_values[idx - 1]
      prev_stats = grouped[prev_value]
      curr_stats = grouped[value]
      return 0.0 unless prev_stats && curr_stats

      marginal_improvement = curr_stats[:success_rate] - prev_stats[:success_rate]
      return 0.0 unless marginal_improvement < DIMINISHING_RETURNS_THRESHOLD

      marginal_improvement.abs * 2.0
    end

    def recommend_iterations(grouped, best_value)
      stats = grouped[best_value]
      return 3 unless stats

      observed = stats[:avg_iterations].round
      [ [ observed, 1 ].max, 10 ].min
    end

    def recommend_parallelism(grouped, best_value)
      stats = grouped[best_value]
      observed = stats&.dig(:observations)&.map { |obs| obs.parallelism_observed.to_i } || []

      return parallelism_cap(best_value) if observed.empty?

      avg_parallelism = (observed.sum.to_f / observed.size).round
      parallelism_cap([ avg_parallelism, best_value ].min)
    end

    def conservative_agent_count
      base = [ inputs.task_count, 2 ].min
      base = [ base, inputs.max_agent_count ].min
      apply_budget_cap(base)
    end

    def apply_budget_cap(agent_count)
      return agent_count unless inputs.budget_constrained?

      observations_with_cost = observations.select { |obs| obs.total_cost_cents.to_i.positive? }
      if observations_with_cost.any?
        avg_cost_per_agent = observations_with_cost.sum(&:total_cost_cents).to_f /
                             observations_with_cost.sum { |obs| obs.agent_count_launched.to_i }
        if avg_cost_per_agent.positive?
          max_affordable = (inputs.budget_cents / avg_cost_per_agent).floor
          return [ agent_count, [ max_affordable, 1 ].max ].min
        end
      end

      agent_count
    end

    def clamp_agents(value)
      clamped = value.clamp(1, inputs.max_agent_count)
      clamped = [ clamped, inputs.task_count ].min
      apply_budget_cap(clamped)
    end

    def grouped
      @grouped ||= group_by_agent_count
    end

    def usable_experiment_summaries
      @usable_experiment_summaries ||= experiment_summaries.select do |summary|
        summary_value(summary, :sample_count, default: 0) >= MIN_OBSERVATIONS_FOR_CONFIDENCE &&
          summary_value(summary, :success_rate, default: 0.0) > MIN_SUCCESS_RATE_FOR_LEARNING
      end
    end

    def summary_value(summary, key, default: nil)
      summary[key] || summary[key.to_s] || default
    end

    def parallelism_cap(agent_count)
      [ agent_count, inputs.parallelism_limit ].min
    end

    def fallback_reason
      reasons = []
      reasons << "insufficient observations (#{observations.size}/#{MIN_OBSERVATIONS_FOR_CONFIDENCE})"
      reasons << "no usable experiment data" unless experiment_summaries_usable?
      reasons.join("; ")
    end

    def observation_reason(grouped, best_value)
      stats = grouped[best_value]
      "best observed agent_count=#{best_value} " \
        "success_rate=#{format_rate(stats[:success_rate])} " \
        "n=#{stats[:count]}"
    end

    def build_allocation(agent_count:, max_iterations:, parallelism_level:, source:, reason:)
      Allocation.new(
        agent_count: agent_count,
        max_iterations: max_iterations,
        parallelism_level: parallelism_level,
        source: source,
        reason: reason,
        metrics: {
          observation_count: observations.size,
          experiment_summary_count: experiment_summaries.size,
          task_count: inputs.task_count,
          complexity_score: inputs.complexity_score.round(4),
          parallelism_potential: inputs.parallelism_potential.round(4)
        }
      )
    end

    def format_rate(value)
      format("%.2f%%", (value || 0.0) * 100)
    end
  end
end
