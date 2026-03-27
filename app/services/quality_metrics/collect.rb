# frozen_string_literal: true

module QualityMetrics
  class Collect
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      @automated_metric = QualityMetric.find_or_initialize_by(
        agent_run: agent_run,
        metric_type: "automated"
      )
      scores = build_scores
      weights = QualityMetric::GOAL_WEIGHTS.fetch(agent_run.goal, QualityMetric::SCORE_WEIGHTS)
      automated_metric.assign_attributes(
        prompt_version: agent_run.prompt_version,
        feedback_source: "system",
        scores: scores,
        composite_score: QualityMetric.weighted_average(scores, weights: weights)
      )
      automated_metric.save!

      update_ab_test_variant_stats(automated_metric)
      update_prompt_version_stats if agent_run.prompt_version.present?
      automated_metric
    end

    private

    attr_reader :agent_run, :automated_metric

    # Builds scores for metrics relevant to the agent run's goal type.
    # `ci_passed` and `tests_pass` are intentionally omitted because the agent run
    # does not track CI/test results separately — the weighted_average method
    # renormalizes over present keys so the composite score remains valid.
    def build_scores
      case agent_run.goal
      when "create_pr" then build_pr_scores
      when "create_issue" then build_issue_scores
      when "review" then build_review_scores
      else build_pr_scores
      end
    end

    def build_pr_scores
      scores = {}
      scores["pr_created"] = agent_run.pull_request_number.present? ? 1.0 : 0.0
      merged = pr_merged_score
      scores["pr_merged"] = merged unless merged.nil?
      scores["iterations"] = iteration_score if agent_run.iterations&.positive?
      lint = lint_clean_score
      scores["lint_clean"] = lint unless lint.nil?
      if agent_run.pull_request_number.present?
        comment_score = review_comment_count_score
        scores["review_comment_count"] = comment_score unless comment_score.nil?
        scores["agent_rerun_count"] = agent_rerun_count_score
      end
      scores
    end

    def build_issue_scores
      scores = {}
      scores["issue_created"] = agent_run.created_issue_number.present? ? 1.0 : 0.0
      scores
    end

    def build_review_scores
      scores = {}
      scores["review_posted"] = agent_run.review_posted_at.present? ? 1.0 : 0.0
      scores
    end

    def pr_merged_score
      return nil unless agent_run.pull_request_number

      issue = agent_run.issue
      return nil unless issue

      issue.pr_review_phase == "merged" ? 1.0 : 0.0
    end

    def iteration_score
      [ 1.0 - ((agent_run.iterations - 1) * 0.1), 0.0 ].max
    end

    # Scores based on the number of review comments on the PR.
    # More review comments suggest lower quality agent output.
    # Score degrades by 0.1 per comment, minimum 0.0.
    # Uses review_comment_count stored in the quality metric metadata
    # by HumanFeedbackCollectionJob.
    # Returns nil when review_comment_count has not yet been collected by
    # HumanFeedbackCollectionJob, so the score is omitted until data is available.
    def review_comment_count_score
      comment_count = automated_metric&.metadata&.dig("review_comment_count")
      return nil if comment_count.nil?

      [ 1.0 - (comment_count.to_i * 0.1), 0.0 ].max
    end

    # Scores based on how many agent runs targeted the same issue.
    # More reruns suggest lower quality of this specific agent run.
    # Score degrades by 0.15 per additional rerun, minimum 0.0.
    def agent_rerun_count_score
      return 1.0 unless agent_run.pull_request_number && agent_run.issue_id

      rerun_count = AgentRun.where(
        issue_id: agent_run.issue_id,
        goal: "create_pr"
      ).where.not(pull_request_number: nil).count

      [ 1.0 - ((rerun_count - 1) * 0.15), 0.0 ].max
    end

    def lint_clean_score
      # Only score lint if the agent actually ran — failed/cancelled/timeout
      # runs that never reached lint should not get a perfect score.
      return nil unless agent_run.successful?

      has_lint_errors = agent_run.agent_run_logs
        .where(log_type: "stderr")
        .where("content ~ ?", "[1-9][0-9]* offense")
        .exists?

      has_lint_errors ? 0.0 : 1.0
    end

    def update_ab_test_variant_stats(metric)
      agent_run.ab_test_assignments.find_each do |assignment|
        variant = assignment.ab_test_variant

        # Lock variant first, then reload assignment inside the lock to get
        # the authoritative old_score. This prevents a concurrent job from
        # seeing old_score as nil and double-incrementing sample_count.
        variant.with_lock do
          assignment.reload
          old_score = assignment.quality_score
          assignment.update!(quality_score: metric.composite_score)

          if old_score.present?
            adjust_variant_aggregates(variant, old_score: old_score, new_score: metric.composite_score)
          else
            # Inline the aggregate update to avoid the redundant nested
            # with_lock inside record_quality_score!.
            add_variant_score(variant, metric.composite_score)
          end
        end
      end
    end

    # Adds a new score to variant aggregates. Assumes caller holds the lock.
    def add_variant_score(variant, score)
      score_decimal = BigDecimal(score.to_s)
      variant.sample_count += 1
      variant.total_quality_score = (variant.total_quality_score || BigDecimal("0")) + score_decimal
      variant.avg_quality_score = variant.total_quality_score / variant.sample_count
      variant.save!
    end

    def adjust_variant_aggregates(variant, old_score:, new_score:)
      old_decimal = BigDecimal(old_score.to_s)
      new_decimal = BigDecimal(new_score.to_s)
      variant.total_quality_score = (variant.total_quality_score || BigDecimal("0")) - old_decimal + new_decimal
      variant.avg_quality_score = variant.sample_count.positive? ? variant.total_quality_score / variant.sample_count : nil
      variant.save!
    end

    def update_prompt_version_stats
      pv = agent_run.prompt_version

      # Scope to automated metrics only so human feedback doesn't inflate
      # usage_count (which represents distinct runs, not total metric rows).
      stats = QualityMetric.where(prompt_version: pv)
                           .automated
                           .with_composite_score
                           .pick(Arel.sql("COUNT(DISTINCT agent_run_id), AVG(composite_score)"))

      count, avg = stats
      pv.update_columns(
        usage_count: count.to_i,
        avg_quality_score: avg&.round(2)
      )
    end
  end
end
