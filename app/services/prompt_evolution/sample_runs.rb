# frozen_string_literal: true

module PromptEvolution
  # Samples recently completed agent runs with quality metrics to evaluate
  # current prompt effectiveness and identify improvement opportunities.
  #
  # Stratifies samples by project, goal type, and quality outcome
  # (above/below threshold) to ensure representative coverage. Calculates
  # aggregate performance statistics from quality metrics per prompt version
  # and flags underperforming prompts for evolution.
  #
  # @example
  #   result = PromptEvolution::SampleRuns.call(sample_size: 50, days: 14)
  #   result.samples            # => [{ agent_run: ..., prompt_version: ..., ... }, ...]
  #   result.prompt_stats       # => { prompt_version_id => { avg_score: 0.82, ... } }
  #   result.evolution_candidates # => [{ prompt_version: ..., reasons: ["..."] }, ...]
  class SampleRuns
    Result = Struct.new(:samples, :prompt_stats, :evolution_candidates, keyword_init: true)

    DEFAULT_SAMPLE_SIZE = 50
    DEFAULT_DAYS = 14
    QUALITY_THRESHOLD = 0.7
    MIN_RUNS_FOR_EVALUATION = 5
    MAX_RUNS_TO_FETCH = 10_000

    attr_reader :sample_size, :days, :project_id

    def initialize(sample_size: DEFAULT_SAMPLE_SIZE, days: DEFAULT_DAYS, project_id: nil)
      @sample_size = sample_size
      @days = days
      @project_id = project_id
    end

    def self.call(...)
      new(...).sample
    end

    def sample
      runs = fetch_completed_runs
      sampled = stratified_sample(runs)
      samples = collect_sample_data(sampled)
      stats = calculate_prompt_stats(samples)
      candidates = identify_evolution_candidates(stats)

      Result.new(samples: samples, prompt_stats: stats, evolution_candidates: candidates)
    end

    private

    def fetch_completed_runs
      scope = AgentRun
        .completed
        .where(completed_at: days.days.ago..)
        .where.not(prompt_version_id: nil)
        .joins(:quality_metrics)
        .merge(QualityMetric.automated.with_composite_score)
        .distinct

      scope = scope.where(project_id: project_id) if project_id
      scope
    end

    def stratified_sample(runs)
      run_rows = runs
        .limit(MAX_RUNS_TO_FETCH)
        .pluck(:id, :project_id, :goal, "quality_metrics.composite_score")
      grouped = run_rows.group_by do |_id, project_id, goal, score|
        [ project_id, goal, quality_bucket(score) ]
      end
      return AgentRun.none if grouped.empty?

      per_stratum = [ sample_size / grouped.size, 1 ].max
      sampled_ids = grouped.flat_map do |_key, stratum_runs|
        stratum_runs.sample(per_stratum).map(&:first)
      end

      AgentRun.where(id: sampled_ids.shuffle.first(sample_size))
    end

    def quality_bucket(score)
      return :unknown unless score

      score >= QUALITY_THRESHOLD ? :above_threshold : :below_threshold
    end

    def collect_sample_data(runs)
      runs.includes(:prompt_version, :quality_metrics, :project).map do |run|
        quality_metric = run.quality_metrics.find { |qm| qm.metric_type == "automated" }
        {
          agent_run: run,
          prompt_version: run.prompt_version,
          project: run.project,
          goal: run.goal,
          composite_score: quality_metric&.composite_score&.to_f,
          cost_cents: run.cost_cents,
          tokens_input: run.tokens_input,
          tokens_output: run.tokens_output,
          duration_seconds: run.duration_seconds
        }
      end
    end

    def calculate_prompt_stats(samples)
      by_version = samples.group_by { |s| s[:prompt_version]&.id }
      by_version.reject { |prompt_version_id, _| prompt_version_id.nil? }.transform_values do |version_samples|
        scores = version_samples.filter_map { |s| s[:composite_score] }
        costs = version_samples.filter_map { |s| s[:cost_cents] }
        durations = version_samples.filter_map { |s| s[:duration_seconds] }

        {
          prompt_version: version_samples.first[:prompt_version],
          run_count: version_samples.size,
          avg_score: scores.any? ? (scores.sum / scores.size).to_f : nil,
          min_score: scores.min,
          max_score: scores.max,
          median_score: median(scores),
          avg_cost_cents: costs.any? ? (costs.sum.to_f / costs.size).round(2) : nil,
          avg_duration_seconds: durations.any? ? (durations.sum.to_f / durations.size).round(2) : nil,
          goal_breakdown: goal_breakdown(version_samples)
        }
      end
    end

    def identify_evolution_candidates(stats)
      stats.filter_map do |_version_id, version_stats|
        next if version_stats[:run_count] < MIN_RUNS_FOR_EVALUATION
        next if version_stats[:avg_score].nil?

        reasons = []
        if version_stats[:avg_score] < QUALITY_THRESHOLD
          reasons << "avg quality score #{version_stats[:avg_score].round(4)} below threshold #{QUALITY_THRESHOLD}"
        end

        goal_stats = version_stats[:goal_breakdown]
        goal_stats.each do |goal, gstats|
          if gstats[:avg_score] && gstats[:avg_score] < QUALITY_THRESHOLD
            reasons << "#{goal} avg score #{gstats[:avg_score].round(4)} below threshold"
          end
        end

        next if reasons.empty?

        {
          prompt_version: version_stats[:prompt_version],
          avg_score: version_stats[:avg_score],
          run_count: version_stats[:run_count],
          reasons: reasons
        }
      end
    end

    def goal_breakdown(version_samples)
      version_samples.group_by { |s| s[:goal] }.transform_values do |goal_samples|
        scores = goal_samples.filter_map { |s| s[:composite_score] }
        {
          run_count: goal_samples.size,
          avg_score: scores.any? ? (scores.sum / scores.size).to_f : nil
        }
      end
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(4)
    end
  end
end
