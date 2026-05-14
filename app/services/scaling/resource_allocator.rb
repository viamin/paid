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
    BLOCKED_RATE_THRESHOLD = 0.20
    LAUNCH_RATE_THRESHOLD = 0.85
    MIN_DURATION_IMPROVEMENT_RATIO = 0.10
    SUCCESS_RATE_DROP_THRESHOLD = 0.15

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
      allocation = allocate_from_observations if observations_fresh_and_sufficient? && grouped.any?
      allocation ||= allocate_from_experiments if experiment_guidance_available?
      allocation || allocate_fallback
    end

    private

    def allocate_from_observations
      best_value = find_optimal_agent_count(grouped)
      iterations = recommend_iterations(grouped, best_value)
      parallelism = recommend_parallelism(grouped, best_value)
      agent_count = clamp_agents(best_value)

      build_allocation(
        agent_count: agent_count,
        max_iterations: iterations,
        parallelism_level: [ parallelism, agent_count ].min,
        source: :observations,
        reason: observation_reason(grouped, best_value)
      )
    end

    def allocate_from_experiments
      decision = measured_experiment_decision
      return allocation_from_measured_decision(decision) if decision

      if (decision_summary = selected_experiment_allocator_decision)
        return allocate_from_experiment_decision(decision_summary)
      end

      return nil if experiment_grouped.empty?
      best_value = find_optimal_agent_count(experiment_grouped)

      stats = experiment_grouped[best_value]
      agent_count = clamp_agents(best_value)
      build_allocation(
        agent_count: agent_count,
        max_iterations: 3,
        parallelism_level: parallelism_cap(agent_count),
        source: :experiment,
        reason: experiment_reason(best_value, stats)
      )
    end

    def allocate_from_experiment_decision(decision_summary)
      decision = decision_summary[:decision]
      requested_agent_count = positive_integer_summary_value(decision, :requested_agent_count, default: conservative_agent_count)
      agent_count = clamp_agents(requested_agent_count)
      recommended_parallelism = positive_integer_summary_value(decision, :max_batch_size, default: parallelism_cap(agent_count))

      build_allocation(
        agent_count: agent_count,
        max_iterations: 3,
        parallelism_level: parallelism_cap([ recommended_parallelism.to_i, agent_count ].min),
        source: :experiment,
        reason: experiment_decision_reason(decision_summary)
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
      fresh_observations.size >= MIN_OBSERVATIONS_FOR_CONFIDENCE
    end

    def fresh_observations
      @fresh_observations ||= observations.select { |obs| obs.created_at > STALE_THRESHOLD.ago }
    end

    def experiment_guidance_available?
      measured_experiment_decision.present? ||
        selected_experiment_allocator_decision.present? ||
        usable_experiment_summaries.any?
    end

    def group_by_agent_count
      supported_groups = fresh_observations.select { |obs| planned_agent_count_for(obs).positive? }
        .group_by { |obs| planned_agent_count_for(obs) }
        .select { |_value, entries| entries.size >= 2 }

      summarize_values(supported_groups)
    end

    def compute_group_stats(group, previous: nil)
      success_rate = group.count(&:success).to_f / group.size
      avg_duration = group.sum { |obs| obs.duration_seconds.to_i }.to_f / group.size
      avg_cost = group.sum(&:total_cost_cents).to_f / group.size
      avg_iterations = group.sum { |obs| obs.total_iterations.to_i }.to_f / group.size
      avg_parallelism = group.sum { |obs| obs.parallelism_observed.to_i }.to_f / group.size
      total_planned = group.sum { |obs| planned_agent_count_for(obs) }
      total_launched = group.sum { |obs| obs.agent_count_launched.to_i }
      total_blocked = group.sum { |obs| obs.agent_count_blocked.to_i }
      launch_rate = ratio(total_launched, total_planned)
      blocked_rate = ratio(total_blocked, total_planned)
      marginal_duration_improvement_ratio = duration_improvement_ratio(previous, avg_duration)
      signals = build_signals(
        previous: previous,
        success_rate: success_rate,
        blocked_rate: blocked_rate,
        launch_rate: launch_rate,
        marginal_duration_improvement_ratio: marginal_duration_improvement_ratio
      )

      {
        count: group.size,
        success_rate: success_rate,
        avg_duration_seconds: avg_duration,
        avg_cost_cents: avg_cost,
        avg_iterations: avg_iterations,
        avg_parallelism_observed: avg_parallelism,
        launch_rate: launch_rate,
        blocked_rate: blocked_rate,
        marginal_duration_improvement_ratio: marginal_duration_improvement_ratio,
        signals: signals,
        observations: group
      }
    end

    def find_optimal_agent_count(grouped_values)
      sorted_values = grouped_values.keys.sort
      return sorted_values.first if sorted_values.size == 1

      safe_candidates = candidate_values(grouped_values)
      scored = safe_candidates.map do |value|
        stats = grouped_values[value]
        score = compute_allocation_score(stats, value, sorted_values, grouped_values)
        { value: value, score: score }
      end

      best = scored.max_by { |entry| entry[:score] }
      best[:value]
    end

    def compute_allocation_score(stats, value, sorted_values, grouped_values)
      success_weight = 0.5
      cost_weight = 0.3
      duration_weight = 0.2

      max_cost = sorted_values.map { |candidate| grouped_values[candidate][:avg_cost_cents] }.max.to_f
      max_duration = sorted_values.map { |candidate| grouped_values[candidate][:avg_duration_seconds] }.max.to_f

      cost_efficiency = max_cost.positive? ? 1.0 - (stats[:avg_cost_cents] / max_cost) : 0.5
      duration_efficiency = max_duration.positive? ? 1.0 - (stats[:avg_duration_seconds] / max_duration) : 0.5

      diminishing_penalty = compute_diminishing_penalty(stats)
      threshold_penalty = threshold_penalty(stats)
      parallelism_bonus = parallelism_bonus(stats, value)

      raw_score = (stats[:success_rate] * success_weight) +
                  (cost_efficiency * cost_weight) +
                  (duration_efficiency * duration_weight) +
                  parallelism_bonus -
                  diminishing_penalty -
                  threshold_penalty

      [ raw_score, 0.0 ].max
    end

    def compute_diminishing_penalty(stats)
      return 0.0 unless stats[:signals]&.include?("diminishing_returns")

      improvement = stats[:marginal_duration_improvement_ratio].to_f
      [ DIMINISHING_RETURNS_THRESHOLD - improvement, 0.0 ].max
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

      avg_cost_per_agent = avg_cost_per_agent_from_observations
      avg_cost_per_agent ||= avg_cost_per_agent_from_experiments

      if avg_cost_per_agent&.positive?
        max_affordable = (inputs.budget_cents / avg_cost_per_agent).floor
        return [ agent_count, [ max_affordable, 1 ].max ].min
      end

      agent_count
    end

    def avg_cost_per_agent_from_observations
      observations_with_cost = fresh_observations.select { |obs| obs.total_cost_cents.to_i.positive? }
      return nil unless observations_with_cost.any?

      total_cost = observations_with_cost.sum(&:total_cost_cents).to_f
      total_agents = observations_with_cost.sum { |obs| obs.agent_count_launched.to_i }
      return nil unless total_agents.positive?

      total_cost / total_agents
    end

    def planned_agent_count_for(observation)
      planned = observation.agent_count_planned.to_i
      return planned if planned.positive?

      observation.agent_count_launched.to_i
    end

    def avg_cost_per_agent_from_experiments
      values_with_cost = normalized_experiment_values.select do |v|
        cost = summary_value(v, :avg_cost_cents, default: 0)
        cost.to_f.positive?
      end
      return nil unless values_with_cost.any?

      total_cost = values_with_cost.sum { |v| summary_value(v, :avg_cost_cents, default: 0).to_f }
      total_cost / values_with_cost.size
    end

    def clamp_agents(value)
      clamped = value.clamp(1, inputs.max_agent_count)
      clamped = [ clamped, inputs.task_count ].min
      apply_budget_cap(clamped)
    end

    def grouped
      @grouped ||= group_by_agent_count
    end

    def experiment_grouped
      @experiment_grouped ||= summarize_values(
        usable_experiment_summaries.group_by do |summary|
          positive_integer_summary_value(summary, :assigned_value) ||
            positive_integer_summary_value(summary, :value)
        end
      )
    end

    def usable_experiment_summaries
      @usable_experiment_summaries ||= normalized_experiment_values.select do |summary|
        sample_count_for(summary) >= MIN_OBSERVATIONS_FOR_CONFIDENCE &&
          summary_value(summary, :success_rate, default: 0.0) > MIN_SUCCESS_RATE_FOR_LEARNING
      end
    end

    def selected_experiment_allocator_decision
      @selected_experiment_allocator_decision ||= experiment_allocator_decisions.max_by do |entry|
        [
          confidence_rank(summary_value(entry[:decision], :confidence)),
          entry[:decision_sample_count]
        ]
      end
    end

    # Only parallelism-dimension summaries carry allocator decisions that
    # should steer agent_count / parallelism_level.  Other dimensions
    # (e.g. iteration_count, max_iterations) may have allocator_decision
    # hashes but their values are not compatible with this code path.
    ALLOCATOR_DECISION_DIMENSIONS = %w[parallelism].freeze

    def experiment_allocator_decisions
      @experiment_allocator_decisions ||= experiment_summaries.filter_map do |summary|
        next unless summary_value(summary, :status).to_s == "ready_for_analysis"
        decision = summary_value(summary, :allocator_decision)
        next unless decision.is_a?(Hash)
        dimension = summary_value(summary, :dimension).to_s
        next unless ALLOCATOR_DECISION_DIMENSIONS.include?(dimension)
        decision_sample_count = sample_count_for(decision)
        next unless decision_sample_count >= MIN_OBSERVATIONS_FOR_CONFIDENCE

        {
          summary: summary,
          decision: decision,
          dimension: summary_value(summary, :dimension),
          sample_count: sample_count_for(summary),
          decision_sample_count: decision_sample_count
        }
      end
    end

    # Normalizes experiment summaries to a flat per-value format.
    # Accepts both flat value hashes (already per-value) and the nested
    # cached_summary shape produced by ScalingExperiments::SummarizeResults,
    # which wraps per-value data in a top-level hash with a "values" array.
    def normalized_experiment_values
      @normalized_experiment_values ||= experiment_summaries.flat_map do |summary|
        status = summary_value(summary, :status)
        next [] if status && status.to_s != "ready_for_analysis"

        values = summary_value(summary, :values)
        if values.is_a?(Array)
          values
        else
          [ summary ]
        end
      end
    end

    def measured_experiment_decision
      @measured_experiment_decision ||= experiment_summaries.filter_map do |summary|
        summary_status = summary_value(summary, :status)
        next if summary_status && summary_status.to_s != "ready_for_analysis"
        dimension = summary_value(summary, :dimension).to_s
        next unless ALLOCATOR_DECISION_DIMENSIONS.include?(dimension)

        analysis = summary_value(summary, :parallelism_analysis, default: {})
        decision = summary_value(analysis, :allocator_decision, default: nil) ||
          summary_value(summary, :allocator_decision, default: nil)
        next unless decision
        next unless summary_value(analysis, :status, default: nil) == "ready"

        sample_count = sample_count_for(analysis, default: sample_count_for(summary))
        decision_sample_count = sample_count_for(decision, default: sample_count)
        # Require the same confidence threshold used for observation cohorts so
        # sparse parallelism analyses (min_samples: 2) cannot override fallback.
        next unless sample_count >= MIN_OBSERVATIONS_FOR_CONFIDENCE
        next unless decision_sample_count >= MIN_OBSERVATIONS_FOR_CONFIDENCE

        { decision: decision, sample_count: sample_count, decision_sample_count: decision_sample_count }
      end.max_by { |entry| [ entry[:decision_sample_count], entry[:sample_count] ] }&.fetch(:decision, nil)
    end

    def allocation_from_measured_decision(decision)
      requested_agent_count = positive_integer_summary_value(decision, :requested_agent_count)
      return nil unless requested_agent_count

      agent_count = clamp_agents(requested_agent_count)
      max_batch_size = positive_integer_summary_value(decision, :max_batch_size, default: requested_agent_count)

      build_allocation(
        agent_count: agent_count,
        max_iterations: 3,
        parallelism_level: parallelism_cap([ max_batch_size.to_i, agent_count ].min),
        source: :experiment,
        reason: "experiment measured returns recommended agent_count=#{requested_agent_count} reason=#{summary_value(decision, :reason, default: 'measured_returns')}"
      )
    end

    def summary_value(summary, key, default: nil)
      return default unless summary.respond_to?(:fetch)

      val = summary.fetch(key) { summary.fetch(key.to_s, default) }
      val.nil? ? default : val
    end

    def integer_summary_value(summary, key, default: nil)
      normalize_integer_value(summary_value(summary, key, default:))
    end

    def positive_integer_summary_value(summary, key, default: nil)
      value = integer_summary_value(summary, key, default:)
      return default unless value&.positive?

      value
    end

    def sample_count_for(summary, default: 0)
      integer_summary_value(summary, :sample_count, default:) || default
    end

    def parallelism_cap(agent_count)
      [ agent_count, inputs.parallelism_limit ].min
    end

    def summarize_values(grouped_values)
      summaries = {}
      previous = nil

      grouped_values.keys.compact.sort.each do |value|
        stats = compute_stats_for_value(value, grouped_values.fetch(value), previous:)
        summaries[value] = stats
        previous = stats
      end

      summaries
    end

    def compute_stats_for_value(value, entries, previous:)
      if observation_entry?(entries.first)
        compute_group_stats(entries, previous:)
      else
        compute_experiment_stats(value, entries, previous:)
      end
    end

    def observation_entry?(entry)
      entry.respond_to?(:agent_count_planned) &&
        entry.respond_to?(:agent_count_launched) &&
        !entry.respond_to?(:fetch)
    end

    def compute_experiment_stats(value, entries, previous:)
      sample_count = entries.sum { |entry| summary_value(entry, :sample_count, default: 0).to_i }
      success_rate = average_metric(entries, :success_rate)
      avg_duration = average_metric(entries, :avg_duration_seconds)
      avg_cost = average_metric(entries, :avg_cost_cents)
      avg_parallelism = average_metric(entries, :avg_parallelism_observed)
      launch_rate = experiment_launch_rate(entries, assigned_value: value)
      blocked_rate = experiment_blocked_rate(entries, assigned_value: value)
      marginal_duration_improvement_ratio = duration_improvement_ratio(previous, avg_duration)
      signals = build_signals(
        previous: previous,
        success_rate: success_rate,
        blocked_rate: blocked_rate,
        launch_rate: launch_rate,
        marginal_duration_improvement_ratio: marginal_duration_improvement_ratio
      )

      {
        count: sample_count,
        success_rate: success_rate,
        avg_duration_seconds: avg_duration,
        avg_cost_cents: avg_cost,
        avg_iterations: 3.0,
        avg_parallelism_observed: avg_parallelism,
        launch_rate: launch_rate,
        blocked_rate: blocked_rate,
        marginal_duration_improvement_ratio: marginal_duration_improvement_ratio,
        signals: signals,
        values: entries,
        assigned_value: value
      }
    end

    def experiment_launch_rate(entries, assigned_value:)
      if metric_present_for_all_entries?(entries, :avg_agent_count_launched)
        launched = average_metric(entries, :avg_agent_count_launched)
        planned = experiment_planned_agent_count(entries, fallback: assigned_value)
        return ratio(launched, planned) if planned.to_f.positive?
      end

      average_metric(entries, :agent_launch_success_rate, fallback: 1.0, ignore_missing: true)
    end

    def experiment_blocked_rate(entries, assigned_value:)
      if metric_present_for_all_entries?(entries, :avg_agent_count_blocked)
        blocked = average_metric(entries, :avg_agent_count_blocked)
        planned = experiment_planned_agent_count(entries, fallback: assigned_value)
        return ratio(blocked, planned) if planned.to_f.positive?
      end

      average_metric(entries, :blocked_task_rate, ignore_missing: true)
    end

    def experiment_planned_agent_count(entries, fallback:)
      return fallback unless metric_present_for_all_entries?(entries, :avg_agent_count_planned)

      planned = average_metric(entries, :avg_agent_count_planned, fallback: fallback)
      planned.to_f.positive? ? planned : fallback
    end

    def build_signals(previous:, success_rate:, blocked_rate:, launch_rate:, marginal_duration_improvement_ratio:)
      [].tap do |signals|
        if previous && marginal_duration_improvement_ratio && marginal_duration_improvement_ratio <= MIN_DURATION_IMPROVEMENT_RATIO
          signals << "diminishing_returns"
        end
        if previous && success_rate <= previous[:success_rate] - SUCCESS_RATE_DROP_THRESHOLD
          signals << "success_rate_regression"
        end
        signals << "blocked_capacity" if blocked_rate >= BLOCKED_RATE_THRESHOLD
        signals << "launch_shortfall" if launch_rate < LAUNCH_RATE_THRESHOLD
      end
    end

    def candidate_values(grouped)
      values_without_threshold_signals = grouped.filter_map do |value, stats|
        value unless threshold_signals?(stats)
      end
      safe_values = values_without_threshold_signals.reject { |value| grouped[value][:signals].include?("diminishing_returns") }

      safe_values.presence || values_without_threshold_signals.presence || grouped.keys.sort
    end

    def threshold_signals?(stats)
      stats[:signals].any? { |signal| signal != "diminishing_returns" }
    end

    def threshold_penalty(stats)
      penalty = 0.0
      penalty += 0.2 if stats[:signals].include?("success_rate_regression")
      penalty += 0.15 if stats[:signals].include?("blocked_capacity")
      penalty += 0.15 if stats[:signals].include?("launch_shortfall")
      penalty
    end

    def parallelism_bonus(stats, value)
      return 0.0 unless value.to_i.positive?

      observed = stats[:avg_parallelism_observed].to_f
      [ observed / value.to_f, 1.0 ].min * 0.05
    end

    def duration_improvement_ratio(previous, avg_duration_seconds)
      return unless previous
      return 0.0 if previous[:avg_duration_seconds].to_f.zero?

      ((previous[:avg_duration_seconds].to_f - avg_duration_seconds.to_f) / previous[:avg_duration_seconds].to_f).round(4)
    end

    def average_metric(entries, key, fallback: 0.0, ignore_missing: false)
      weighted_sum = 0.0
      total_weight = 0

      entries.each do |entry|
        weight = summary_value(entry, :sample_count, default: 0).to_i
        next if weight <= 0

        if ignore_missing && !metric_present?(entry, key)
          next
        end

        weighted_sum += summary_value(entry, key, default: fallback).to_f * weight
        total_weight += weight
      end

      return fallback if total_weight.zero?

      weighted_sum / total_weight
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.to_f <= 0.0

      numerator.to_f / denominator.to_f
    end

    def normalize_integer_value(value)
      case value
      when Integer
        value
      when Float
        value.finite? && value == value.to_i ? value.to_i : nil
      when String
        /\A\d+\z/.match?(value) ? value.to_i : nil
      else
        nil
      end
    end

    def experiment_decision_reason(decision_summary)
      decision = decision_summary[:decision]

      "#{decision_summary[:dimension]} allocator decision " \
        "agents=#{summary_value(decision, :requested_agent_count, default: conservative_agent_count)} " \
        "parallelism=#{summary_value(decision, :max_batch_size, default: nil)} " \
        "n=#{decision_summary[:decision_sample_count]} " \
        "confidence=#{summary_value(decision, :confidence, default: "unknown")}"
    end

    def metric_present_for_all_entries?(entries, key)
      return false if entries.empty?

      entries.all? { |entry| metric_present?(entry, key) }
    end

    def metric_present?(entry, key)
      return false unless entry.respond_to?(:fetch)

      entry.key?(key) || entry.key?(key.to_s)
    end

    def fallback_reason
      reasons = []
      reasons << "insufficient fresh observations (#{fresh_observations.size}/#{MIN_OBSERVATIONS_FOR_CONFIDENCE})"
      reasons << "no usable experiment data" unless experiment_guidance_available?
      reasons.join("; ")
    end

    def observation_reason(grouped, best_value)
      stats = grouped[best_value]
      "best observed agent_count=#{best_value} " \
        "success_rate=#{format_rate(stats[:success_rate])} " \
        "signals=#{stats[:signals].join(',').presence || 'none'} " \
        "n=#{stats[:count]}"
    end

    def experiment_reason(best_value, stats)
      "experiment leading value=#{best_value} " \
        "success_rate=#{format_rate(stats[:success_rate])} " \
        "signals=#{stats[:signals].join(',').presence || 'none'} " \
        "n=#{stats[:count]}"
    end

    def build_allocation(agent_count:, max_iterations:, parallelism_level:, source:, reason:)
      Allocation.new(
        agent_count: agent_count,
        max_iterations: max_iterations,
        parallelism_level: [ parallelism_level, agent_count ].min,
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

    def confidence_rank(value)
      case value
      when "high" then 2
      when "medium" then 1
      else 0
      end
    end
  end
end
