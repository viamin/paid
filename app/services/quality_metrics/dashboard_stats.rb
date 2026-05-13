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

    def self.overview_cache_key(project_id)
      "quality_dashboard_overview/#{project_id}"
    end

    def call
      {
        overview: overview,
        trends: trends,
        breakdown: score_breakdown,
        prompt_comparison: prompt_comparison,
        model_comparison: model_comparison,
        tier_breakdown: tier_breakdown,
        human_feedback: human_feedback,
        gate_status: gate_status,
        metrics_reference: self.class.metrics_reference
      }
    end

    # Display metadata for each metric key: human-readable name, description,
    # signal type, and which goal types collect this metric. The collected_for
    # field is decoupled from GOAL_WEIGHTS because some metrics (e.g. review_score,
    # reaction_score for create_pr) are collected via human feedback but do not
    # carry a scoring weight.
    METRIC_DISPLAY = {
      "pr_created" => { name: "PR Created", description: "Whether the agent successfully created a pull request.", signal_type: "automated", collected_for: %w[create_pr] },
      "pr_merged" => { name: "PR Merged", description: "Whether the pull request was merged.", signal_type: "human", collected_for: %w[create_pr] },
      "ci_passed" => { name: "CI Passed", description: "Whether CI checks passed on the pull request.", signal_type: "automated", collected_for: %w[create_pr] },
      "focus_resolved" => { name: "Focus Resolved", description: "Whether the focused run resolved the specific PR problem it was targeting on the next scan cycle.", signal_type: "automated", collected_for: %w[create_pr] },
      "iterations" => { name: "Iterations", description: "Fewer iterations to complete = higher quality. Degrades by 0.1 per extra iteration.", signal_type: "automated", collected_for: %w[create_pr] },
      "lint_clean" => { name: "Lint Clean", description: "Whether the agent produced code with no lint offenses.", signal_type: "automated", collected_for: %w[create_pr] },
      "tests_pass" => { name: "Tests Pass", description: "Whether tests pass on the agent's output.", signal_type: "automated", collected_for: %w[create_pr] },
      "review_comment_count" => { name: "Review Comment Count", description: "Fewer review comments = higher quality output. Degrades by 0.1 per comment.", signal_type: "human", collected_for: %w[create_pr] },
      "agent_rerun_count" => { name: "Agent Rerun Count", description: "Fewer reruns per issue = higher quality agent run. Degrades by 0.15 per extra rerun.", signal_type: "automated", collected_for: %w[create_pr] },
      "issue_created" => { name: "Issue Created", description: "Whether the agent successfully created an issue.", signal_type: "automated", collected_for: %w[create_issue] },
      "reaction_score" => { name: "Reaction Score", description: "Ratio of positive to total emoji reactions. Positive: +1, heart, hooray, rocket. Negative: -1, confused.", signal_type: "human", collected_for: %w[create_pr create_issue review enhance_issue] },
      "review_posted" => { name: "Review Posted", description: "Whether the agent successfully posted a code review.", signal_type: "automated", collected_for: %w[review] },
      "review_score" => { name: "Review Score", description: "Average score from PR review outcomes. Approved=1.0, commented=0.5, changes_requested=0.0.", signal_type: "human", collected_for: %w[create_pr] },
      "comment_posted" => { name: "Comment Posted", description: "Whether the agent successfully posted an issue enhancement comment.", signal_type: "automated", collected_for: %w[enhance_issue] },
      "author_replied" => { name: "Author Replied", description: "Whether the original issue author replied after the enhancement comment.", signal_type: "human", collected_for: %w[enhance_issue] },
      "question_count" => { name: "Question Count", description: "Normalized score for clarifying questions asked in the enhancement comment.", signal_type: "automated", collected_for: %w[enhance_issue] }
    }.freeze

    # Returns a structured reference of all quality metrics with their
    # per-goal weights, descriptions, and applicable goal types.
    # Weights are returned per goal type to avoid misleading display when a
    # metric is collected for a goal but not weighted for it (e.g.
    # reaction_score is collected for create_pr but only weighted for
    # create_issue and review).
    def self.metrics_reference
      METRIC_DISPLAY.map do |key, display|
        weights_by_goal = {}
        QualityMetric::GOAL_WEIGHTS.each do |goal, weights|
          weights_by_goal[goal] = weights[key] if weights.key?(key)
        end

        weights_by_focus = {}
        QualityMetric::FOCUS_WEIGHTS.each do |focus, weights|
          weights_by_focus[focus.to_s] = weights[key] if weights.key?(key)
        end

        {
          key: key,
          name: display[:name],
          description: display[:description],
          weights_by_goal: weights_by_goal,
          weights_by_focus: weights_by_focus,
          goal_types: display[:collected_for],
          signal_type: display[:signal_type]
        }
      end
    end

    DISTRIBUTION_BANDS = [
      { label: "0–20", min: 0.0, max: 0.2 },
      { label: "20–40", min: 0.2, max: 0.4 },
      { label: "40–60", min: 0.4, max: 0.6 },
      { label: "60–80", min: 0.6, max: 0.8 },
      { label: "80–100", min: 0.8, max: 1.01 }
    ].freeze

    OVERVIEW_CACHE_TTL = 2.minutes

    def overview
      Rails.cache.fetch(self.class.overview_cache_key(project.id), expires_in: OVERVIEW_CACHE_TTL) do
        compute_overview
      end
    end

    def compute_overview
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
        human_count: row.human_count.to_i,
        score_distribution: score_distribution
      }
    end

    private :compute_overview

    def export_data(limit: 10_000)
      metrics_scope = QualityMetric.by_project(project.id)
        .includes(:prompt_version, agent_run: :model_selection)
        .order(created_at: :desc)
        .limit(limit)

      metrics_scope.map do |m|
        selection = m.agent_run&.model_selection
        {
          id: m.id,
          date: m.created_at.iso8601,
          metric_type: m.metric_type,
          composite_score: m.composite_score&.to_f,
          scores: m.scores,
          feedback_source: m.feedback_source,
          agent_run_id: m.agent_run_id,
          provider: m.agent_run&.effective_provider,
          goal: m.agent_run&.goal,
          prompt_version: m.prompt_version&.version,
          tier: selection&.tier,
          complexity_score: selection&.complexity_score&.to_f
        }
      end
    end

    private

    def metrics
      @metrics ||= QualityMetric.by_project(project.id).with_composite_score
        .joins(:agent_run).where(AgentRun.quality_scoreable_sql)
    end

    def score_distribution
      counts = metrics
        .group(Arel.sql(<<~SQL.squish))
          CASE
            WHEN composite_score < 0.2 THEN 0
            WHEN composite_score < 0.4 THEN 1
            WHEN composite_score < 0.6 THEN 2
            WHEN composite_score < 0.8 THEN 3
            ELSE 4
          END
        SQL
        .count

      DISTRIBUTION_BANDS.each_with_index.map do |band, i|
        { label: band[:label], min: band[:min], count: counts.fetch(i, 0) }
      end
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
      valid_keys = (
        QualityMetric::GOAL_WEIGHTS.values.flat_map(&:keys) +
        QualityMetric::FOCUS_WEIGHTS.values.flat_map(&:keys)
      ).uniq
      rows = QualityMetric.by_project(project.id).automated.with_composite_score
        .joins(:agent_run).where(AgentRun.quality_scoreable_sql)
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
          pr_merge: source_tally["pr_merge"].to_i,
          pr_reaction: source_tally["pr_reaction"].to_i,
          pr_review: source_tally["pr_review"].to_i,
          issue_reaction: source_tally["issue_reaction"].to_i,
          review_reaction: source_tally["review_reaction"].to_i,
          comment: source_tally["comment"].to_i
        }
      }
    end

    def model_comparison
      runs_with_metrics = AgentRun.where(project: project)
        .joins(:quality_metrics)
        .where(quality_metrics: { composite_score: ..Float::INFINITY })
        .where.not(quality_metrics: { composite_score: nil })
        .select(
          Arel.sql("#{AgentRun.effective_provider_sql} AS eff_provider"),
          "AVG(quality_metrics.composite_score) AS avg_score",
          "COUNT(quality_metrics.id) AS sample_size"
        )
        .group(Arel.sql(AgentRun.effective_provider_sql))
        .to_a

      runs_with_metrics.filter_map do |row|
        next if row.eff_provider.blank?

        {
          provider: row.eff_provider,
          avg_score: row.avg_score.to_f.round(4),
          sample_size: row.sample_size.to_i
        }
      end.sort_by { |r| -r[:avg_score] }
    end

    def tier_breakdown
      runs_with_tier = AgentRun.where(project: project)
        .joins(:model_selection)
        .where.not(model_selections: { tier: nil })

      tier_quality = runs_with_tier
        .joins(:quality_metrics)
        .where.not(quality_metrics: { composite_score: nil })
        .group("model_selections.tier")
        .select(
          "model_selections.tier",
          "AVG(quality_metrics.composite_score) AS avg_score",
          "COUNT(DISTINCT quality_metrics.id) AS sample_size"
        )
        .to_a

      tier_counts = runs_with_tier
        .group("model_selections.tier")
        .count

      escalation_count = runs_with_tier
        .where(model_selections: { selector_type: "quality_escalation" })
        .group("model_selections.tier")
        .count

      LlmModel::TIERS.map do |tier|
        quality_row = tier_quality.find { |r| r.tier == tier }
        run_count = tier_counts[tier] || 0
        escalations = escalation_count[tier] || 0

        {
          tier: tier,
          run_count: run_count,
          avg_score: quality_row&.avg_score&.to_f&.round(4),
          sample_size: quality_row&.sample_size&.to_i || 0,
          escalation_count: escalations,
          escalation_rate: run_count.zero? ? nil : (escalations.to_f / run_count * 100).round(1)
        }
      end
    end

    def gate_status
      thresholds = QualityThreshold.effective_for(project: project)
      return { thresholds: [], recent_events: [], active_breaches: 0 } if thresholds.empty?

      recent_events = project.quality_pause_events
        .order(created_at: :desc)
        .limit(20)
        .map do |e|
          {
            event_type: e.event_type == "paused" ? "trigger" : "recovery",
            metric_key: e.metadata["metric_type"].presence || "composite_score",
            goal_type: e.metadata["goal_type"],
            severity: "critical",
            score_value: e.composite_score&.to_f,
            threshold_value: e.threshold&.to_f,
            created_at: e.created_at.iso8601
          }
        end

      {
        thresholds: thresholds.map do |t|
          {
            metric_key: t.metric_type,
            goal_type: t.goal_type,
            min_threshold: t.min_value&.to_f,
            max_threshold: nil,
            severity: t.enabled? ? "critical" : "info",
            source_scope: t.source_scope
          }
        end,
        recent_events: recent_events,
        active_breaches: active_threshold_breaches(thresholds)
      }
    end

    def active_threshold_breaches(thresholds)
      thresholds.count do |threshold|
        scores = recent_scores_for(threshold)
        next false if scores.size < QualityThreshold::DEFAULT_MIN_SAMPLE_SIZE

        average = scores.sum / scores.size
        threshold.breached?(average)
      end
    end

    def recent_scores_for(threshold)
      metrics_for_threshold(threshold).limit(QualityThreshold::DEFAULT_WINDOW_SIZE).filter_map do |metric|
        if threshold.metric_type == "composite_score"
          metric.composite_score&.to_f
        else
          metric.scores&.dig(threshold.metric_type)&.to_f
        end
      end
    end

    def metrics_for_threshold(threshold)
      scope = QualityMetric.by_project(project.id)
        .joins(:agent_run)
        .where(agent_runs: { goal: threshold.goal_type })
        .where(AgentRun.quality_scoreable_sql)
        .order(created_at: :desc)

      if threshold.metric_type == "composite_score"
        scope.where.not(composite_score: nil)
      else
        scope.where("jsonb_exists(quality_metrics.scores, ?)", threshold.metric_type)
      end
    end

    def empty_human_feedback
      {
        total: 0,
        merge_rate: nil,
        reactions: { count: 0, average_score: nil },
        reviews: { count: 0, average_score: nil },
        by_source: { pr_merge: 0, pr_reaction: 0, pr_review: 0, issue_reaction: 0, review_reaction: 0, comment: 0 }
      }
    end
  end
end
