# frozen_string_literal: true

module ScalingExperiments
  class SummarizeResults
    CONFIDENCE_LEVEL = 0.95

    def self.call(...)
      new(...).call
    end

    def initialize(scaling_experiment:)
      @scaling_experiment = scaling_experiment
    end

    def call
      summaries = value_summaries
      analysis = parallelism_analysis
      scaling_law = scaling_law_analysis(summaries)
      control = summaries.find { |summary| summary["assigned_value"] == scaling_experiment.control_value }
      leader = summaries.max_by { |summary| leader_sort_key(summary) }

      {
        "status" => scaling_experiment.sufficient_samples? ? "ready_for_analysis" : "collecting",
        "dimension" => scaling_experiment.dimension,
        "control_value" => scaling_experiment.control_value,
        "primary_metric" => primary_metric,
        "confidence_level" => CONFIDENCE_LEVEL,
        "outcome_metric_keys" => scaling_experiment.outcome_metrics.map { |metric| metric["key"] },
        "cohort_strategy" => scaling_experiment.cohort_settings.slice("assignment_strategy", "cadence", "label_template"),
        "sample_count" => summaries.sum { |summary| summary["sample_count"] },
        "values" => summaries,
        "scaling_law" => scaling_law,
        "parallelism_analysis" => analysis,
        "allocator_decision" => allocator_decision_for(scaling_law, analysis),
        "leading_value" => leader&.fetch("assigned_value", nil),
        "sample_threshold_review" => sample_threshold_review,
        "simplifications" => simplifications,
        "improvement_over_control" => (comparison = improvement_over_control(control:, leader:)),
        "initial_results" => initial_results(control:, leader:, comparison:)
      }.compact
    end

    private

    attr_reader :scaling_experiment

    def primary_metric
      metric = scaling_experiment.outcome_metrics.find { |candidate| candidate["primary"] == true }
      metric&.fetch("key", nil)
    end

    def value_summaries
      assignments_by_value = loaded_assignments.group_by(&:assigned_value)

      scaling_experiment.values_tested.map(&:to_i).uniq.sort.map do |value|
        assignments = assignments_by_value.fetch(value, [])
        observations = assignments.filter_map(&:scaling_observation)
        {
          "assigned_value" => value,
          "sample_count" => observations.size,
          "success_rate" => rate(observations, &:success),
          "success_rate_confidence_interval" => rate_confidence_interval(observations, &:success),
          "avg_total_iterations" => average(observations, &:total_iterations),
          "avg_max_iterations" => average(observations, &:max_iterations),
          "avg_duration_seconds" => average(observations, &:duration_seconds),
          "avg_duration_seconds_confidence_interval" => mean_confidence_interval(observations, &:duration_seconds),
          "avg_cost_cents" => average(observations, &:total_cost_cents),
          "avg_cost_cents_confidence_interval" => mean_confidence_interval(observations, &:total_cost_cents),
          "agent_launch_success_rate" => aggregated_proportion(assignments, numerator_key: "agent_count_succeeded", denominator_key: "agent_count_launched"),
          "agent_launch_success_rate_confidence_interval" => aggregated_proportion_confidence_interval(
            assignments,
            numerator_key: "agent_count_succeeded",
            denominator_key: "agent_count_launched"
          ),
          "blocked_task_rate" => aggregated_proportion(assignments, numerator_key: "agent_count_blocked", denominator_key: "task_count"),
          "blocked_task_rate_confidence_interval" => aggregated_proportion_confidence_interval(
            assignments,
            numerator_key: "agent_count_blocked",
            denominator_key: "task_count"
          ),
          "avg_quality_score" => average_quality_score(assignments),
          "avg_quality_score_confidence_interval" => mean_confidence_interval_from_summaries(assignments, "avg_quality_score"),
          "quality_metric_sample_count" => quality_metric_sample_count(assignments),
          "avg_parallelism_observed" => average(observations, &:parallelism_observed),
          "avg_parallelism_observed_confidence_interval" => mean_confidence_interval(observations, &:parallelism_observed),
          "avg_agent_count_launched" => average(observations, &:agent_count_launched),
          "cohort_labels" => assignments.map { |assignment| assignment.outcome_summary["cohort_label"] }.compact.uniq.sort,
          "status_tally" => observations.map(&:status).tally
        }
      end
    end

    def loaded_assignments
      @loaded_assignments ||= scaling_experiment.scaling_experiment_assignments
        .recorded
        .includes(:scaling_observation)
        .to_a
    end

    def recorded_observations
      @recorded_observations ||= loaded_assignments.filter_map(&:scaling_observation)
    end

    def parallelism_analysis
      ScalingObservations::AnalyzeParallelism.call(observations: recorded_observations).to_h
    end

    def scaling_law_analysis(summaries)
      ScalingExperiments::AnalyzeScalingLaw.call(
        scaling_experiment: scaling_experiment,
        value_summaries: summaries,
        confidence_level: CONFIDENCE_LEVEL
      ).to_h
    end

    def sample_threshold_review
      configured = experiment_min_samples_per_value

      {
        "configured_min_samples_per_value" => configured,
        "analysis_min_samples_per_value" => [ configured, ScalingExperiments::AnalyzeScalingLaw::MIN_SAMPLES ].max,
        "rdr_target_min_samples_per_value" => ScalingExperiments::AnalyzeScalingLaw::RDR_TARGET_MIN_SAMPLES_PER_VALUE,
        "meets_rdr_target" => configured >= ScalingExperiments::AnalyzeScalingLaw::RDR_TARGET_MIN_SAMPLES_PER_VALUE
      }
    end

    def simplifications
      [
        "Confidence intervals use Wilson intervals for rates and normal-approximation intervals for means.",
        "Scaling exponent confidence uses a log-log linear fit instead of the full regression suite proposed in the RDR.",
        "The dashboard flags experiments configured below the 30-sample RDR target instead of enforcing that threshold retroactively."
      ]
    end

    def allocator_decision_for(scaling_law, parallelism_analysis)
      if scaling_experiment.dimension == "parallelism"
        parallelism_analysis["allocator_decision"] || scaling_law["allocator_decision"]
      else
        scaling_law["allocator_decision"]
      end
    end

    def improvement_over_control(control:, leader:)
      return unless control && leader

      {
        "quality_score_delta" => delta(leader["avg_quality_score"], control["avg_quality_score"]),
        "success_rate_delta" => delta(leader["success_rate"], control["success_rate"]),
        "duration_seconds_delta" => delta(leader["avg_duration_seconds"], control["avg_duration_seconds"]),
        "cost_cents_delta" => delta(leader["avg_cost_cents"], control["avg_cost_cents"]),
        "agent_launch_success_rate_delta" => delta(leader["agent_launch_success_rate"], control["agent_launch_success_rate"]),
        "blocked_task_rate_delta" => delta(leader["blocked_task_rate"], control["blocked_task_rate"])
      }
    end

    def initial_results(control:, leader:, comparison:)
      {
        "control" => control,
        "leader" => leader,
        "comparison" => comparison,
        "recorded_sample_counts" => scaling_experiment.samples_key
      }.compact
    end

    def leader_sort_key(summary)
      [
        summary["quality_metric_sample_count"].to_i.positive? ? 1 : 0,
        summary["avg_quality_score"].to_f,
        summary["success_rate"],
        summary["sample_count"],
        -summary["avg_duration_seconds"],
        -summary["avg_cost_cents"]
      ]
    end

    def average_quality_score(assignments)
      quality_scores = assignments.filter_map { |assignment| assignment.outcome_summary["avg_quality_score"]&.to_f }
      return nil if quality_scores.empty?

      (quality_scores.sum / quality_scores.size).round(4)
    end

    def aggregated_proportion(assignments, numerator_key:, denominator_key:)
      successes, trials = aggregated_counts(assignments, numerator_key:, denominator_key:)
      return nil unless successes
      return 0.0 if trials.zero?

      (successes.to_f / trials).round(4)
    end

    def aggregated_proportion_confidence_interval(assignments, numerator_key:, denominator_key:)
      successes, trials = aggregated_counts(assignments, numerator_key:, denominator_key:)
      return ScalingExperiments::Statistics.proportion_interval(successes: 0, trials: 0, confidence_level: CONFIDENCE_LEVEL) unless successes

      ScalingExperiments::Statistics.proportion_interval(
        successes:,
        trials:,
        confidence_level: CONFIDENCE_LEVEL
      )
    end

    def aggregated_counts(assignments, numerator_key:, denominator_key:)
      counts = assignments.filter_map do |assignment|
        numerator = count_metric_for(assignment, numerator_key)
        denominator = count_metric_for(assignment, denominator_key)
        next if numerator.nil? || denominator.nil?

        [ numerator, denominator ]
      end
      return unless counts.any?

      [ counts.sum(&:first), counts.sum(&:last) ]
    end

    def count_metric_for(assignment, key)
      summary = assignment.outcome_summary

      summary[key] || summary.dig("observation", key) || assignment.scaling_observation&.public_send(key)
    end

    def mean_confidence_interval(observations)
      values = observations.filter_map { |observation| yield(observation)&.to_f }
      ScalingExperiments::Statistics.mean_interval(values:, confidence_level: CONFIDENCE_LEVEL)
    end

    def mean_confidence_interval_from_summaries(assignments, key)
      values = assignments.filter_map { |assignment| assignment.outcome_summary[key]&.to_f }
      ScalingExperiments::Statistics.mean_interval(values:, confidence_level: CONFIDENCE_LEVEL)
    end

    def rate_confidence_interval(observations)
      successes = observations.count { |observation| yield(observation) }
      ScalingExperiments::Statistics.proportion_interval(
        successes:,
        trials: observations.size,
        confidence_level: CONFIDENCE_LEVEL
      )
    end

    def quality_metric_sample_count(assignments)
      assignments.sum { |assignment| assignment.outcome_summary["quality_metric_sample_count"].to_i }
    end

    def delta(value, control)
      return unless value && control

      (value - control).round(4)
    end

    def rate(observations)
      return 0.0 if observations.empty?

      (observations.count { |observation| yield(observation) }.to_f / observations.size).round(4)
    end

    def average(observations)
      return 0.0 if observations.empty?

      (observations.sum { |observation| yield(observation).to_f } / observations.size).round(4)
    end

    def experiment_min_samples_per_value
      scaling_experiment.min_samples_per_value.to_i
    end
  end
end
