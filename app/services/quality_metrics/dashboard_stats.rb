# frozen_string_literal: true

module QualityMetrics
  # Computes quality metrics dashboard data for a project.
  # Provides composite scores, trends, breakdowns, prompt comparisons,
  # and human feedback summaries.
  #
  # @example
  #   stats = QualityMetrics::DashboardStats.call(project: project)
  class DashboardStats
    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def self.overview(...)
      new(...).overview
    end

    def call
      {
        overview: overview,
        trends: trends,
        breakdown: score_breakdown,
        prompt_comparison: prompt_comparison,
        human_feedback: human_feedback,
        metrics_reference: self.class.metrics_reference
      }
    end

    # Display metadata for each metric key: human-readable name, description,
    # and signal type. Weights and goal_types are derived from QualityMetric::GOAL_WEIGHTS.
    METRIC_DISPLAY = {
      "pr_created" => { name: "PR Created", description: "Whether the agent successfully created a pull request.", signal_type: "automated" },
      "pr_merged" => { name: "PR Merged", description: "Whether the pull request was merged.", signal_type: "automated" },
      "ci_passed" => { name: "CI Passed", description: "Whether CI checks passed on the pull request.", signal_type: "automated" },
      "iterations" => { name: "Iterations", description: "Fewer iterations to complete = higher quality. Degrades by 0.1 per extra iteration.", signal_type: "automated" },
      "lint_clean" => { name: "Lint Clean", description: "Whether the agent produced code with no lint offenses.", signal_type: "automated" },
      "tests_pass" => { name: "Tests Pass", description: "Whether tests pass on the agent's output.", signal_type: "automated" },
      "review_comment_count" => { name: "Review Comment Count", description: "Fewer review comments = higher quality output. Degrades by 0.1 per comment.", signal_type: "human" },
      "agent_rerun_count" => { name: "Agent Rerun Count", description: "Fewer reruns per PR = higher quality agent run. Degrades by 0.15 per extra rerun.", signal_type: "human" },
      "issue_created" => { name: "Issue Created", description: "Whether the agent successfully created an issue.", signal_type: "automated" },
      "reaction_score" => { name: "Reaction Score", description: "Ratio of positive to total emoji reactions. Positive: +1, heart, hooray, rocket. Negative: -1, confused.", signal_type: "human" },
      "review_posted" => { name: "Review Posted", description: "Whether the agent successfully posted a code review.", signal_type: "automated" },
      "review_score" => { name: "Review Score", description: "Average score from PR review outcomes. Approved=1.0, commented=0.5, changes_requested=0.0.", signal_type: "human" }
    }.freeze

    # Returns a structured reference of all quality metrics with their
    # weights, descriptions, and applicable goal types.
    # Weights are derived from QualityMetric::GOAL_WEIGHTS to avoid duplication.
    def self.metrics_reference
      # Build a mapping of metric_key -> { weights_by_goal, goal_types }
      weights_index = Hash.new { |h, k| h[k] = { weights: {}, goal_types: [] } }
      QualityMetric::GOAL_WEIGHTS.each do |goal, weights|
        weights.each do |key, weight|
          weights_index[key][:weights][goal] = weight
          weights_index[key][:goal_types] << goal
        end
      end

      METRIC_DISPLAY.map do |key, display|
        entry = weights_index[key]
        # Use the first goal's weight as the representative weight (all goals
        # with this metric currently use the same weight per metric key).
        weight = entry[:weights].values.first

        {
          key: key,
          name: display[:name],
          description: display[:description],
          weight: weight,
          goal_types: entry[:goal_types],
          signal_type: display[:signal_type]
        }
      end
    end

    def overview
      row = metrics
        .select(
          "COUNT(*) AS total_metrics",
          "AVG(composite_score) AS avg_score",
          "MIN(composite_score) AS min_score",
          "MAX(composite_score) AS max_score",
          "COUNT(*) FILTER (WHERE metric_type = 'automated') AS automated_count",
          "COUNT(*) FILTER (WHERE metric_type = 'human') AS human_count"
        )
        .take

      {
        total_metrics: row.total_metrics.to_i,
        average_score: row.avg_score&.to_f&.round(4),
        min_score: row.min_score&.to_f,
        max_score: row.max_score&.to_f,
        automated_count: row.automated_count.to_i,
        human_count: row.human_count.to_i
      }
    end

    private

    def metrics
      @metrics ||= QualityMetric.by_project(project.id).with_composite_score
    end

    def trends
      recent = metrics
        .select("quality_metrics.composite_score, quality_metrics.created_at, quality_metrics.metric_type")
        .order("quality_metrics.created_at DESC")
        .limit(30)

      recent.reverse.map do |m|
        {
          score: m.composite_score.to_f,
          date: m.created_at.to_date.iso8601,
          metric_type: m.metric_type
        }
      end
    end

    def score_breakdown
      valid_keys = QualityMetric::GOAL_WEIGHTS.values.flat_map(&:keys).uniq
      rows = QualityMetric.by_project(project.id).automated.with_composite_score
        .where("scores <> '{}'::jsonb")
        .joins("CROSS JOIN LATERAL jsonb_each_text(scores) AS kv(key, val)")
        .where("kv.key IN (?)", valid_keys)
        .group("kv.key")
        .pluck(Arel.sql("kv.key, AVG(kv.val::float)"))

      rows.to_h { |key, avg| [ key, avg.to_f.round(4) ] }
    end

    def prompt_comparison
      version_metrics = metrics.where.not(prompt_version_id: nil)
        .group(:prompt_version_id)
        .select(
          "prompt_version_id",
          "AVG(composite_score) AS avg_score",
          "COUNT(*) AS sample_size"
        )
        .to_a

      return [] if version_metrics.empty?

      version_ids = version_metrics.map(&:prompt_version_id)
      versions_by_id = PromptVersion.includes(:prompt).where(id: version_ids).index_by(&:id)

      version_metrics.filter_map do |row|
        version = versions_by_id[row.prompt_version_id]
        next unless version

        {
          prompt_version_id: row.prompt_version_id,
          prompt_name: version.prompt.name,
          version_number: version.version,
          avg_score: row.avg_score.to_f.round(4),
          sample_size: row.sample_size.to_i
        }
      end.sort_by { |r| -r[:avg_score] }
    end

    def human_feedback
      human = QualityMetric.by_project(project.id).human

      row = human.select(
        "COUNT(*) AS total",
        "COUNT(*) FILTER (WHERE scores ? 'pr_merged') AS with_merge_status",
        "COUNT(*) FILTER (WHERE (scores->>'pr_merged')::float = 1.0) AS merged_count",
        "AVG((scores->>'reaction_score')::float) FILTER (WHERE scores ? 'reaction_score') AS avg_reaction",
        "COUNT(*) FILTER (WHERE scores ? 'reaction_score') AS reaction_count",
        "AVG((scores->>'review_score')::float) FILTER (WHERE scores ? 'review_score') AS avg_review",
        "COUNT(*) FILTER (WHERE scores ? 'review_score') AS review_count"
      ).take

      total = row.total.to_i
      return empty_human_feedback if total.zero?

      with_merge_status = row.with_merge_status.to_i
      merged_count = row.merged_count.to_i

      # Tally feedback sources in SQL via jsonb_array_elements_text to avoid
      # loading all rows into Ruby (O(N) memory on large projects).
      source_tally = human
        .where("metadata ? 'feedback_sources'")
        .joins("CROSS JOIN LATERAL jsonb_array_elements_text(metadata->'feedback_sources') AS src(val)")
        .group("src.val")
        .pluck(Arel.sql("src.val, COUNT(*)"))
        .to_h

      {
        total: total,
        merge_rate: with_merge_status.zero? ? nil : (merged_count.to_f / with_merge_status * 100).round(1),
        reactions: {
          count: row.reaction_count.to_i,
          average_score: row.avg_reaction&.to_f&.round(4)
        },
        reviews: {
          count: row.review_count.to_i,
          average_score: row.avg_review&.to_f&.round(4)
        },
        by_source: {
          pr_reaction: source_tally["pr_reaction"].to_i,
          pr_review: source_tally["pr_review"].to_i,
          issue_reaction: source_tally["issue_reaction"].to_i,
          review_reaction: source_tally["review_reaction"].to_i
        }
      }
    end

    def empty_human_feedback
      {
        total: 0,
        merge_rate: nil,
        reactions: { count: 0, average_score: nil },
        reviews: { count: 0, average_score: nil },
        by_source: { pr_reaction: 0, pr_review: 0, issue_reaction: 0, review_reaction: 0 }
      }
    end
  end
end
