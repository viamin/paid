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
      @score_metadata = {}

      if agent_run.operational_failure?
        record_excluded_metric
      else
        record_quality_metric
        update_ab_test_variant_stats(automated_metric)
        update_prompt_version_stats if agent_run.prompt_version.present?
      end

      enqueue_quality_gate_check
      automated_metric
    end

    private

    attr_reader :agent_run, :automated_metric, :score_metadata

    def record_excluded_metric
      automated_metric.assign_attributes(
        prompt_version: agent_run.prompt_version,
        feedback_source: "system",
        scores: { "excluded_status" => agent_run.status },
        metadata: (automated_metric.metadata || {}).merge(
          score_metadata.merge(
            "exclusion_reason" => "operational_failure",
            "error_message" => agent_run.error_message.to_s.truncate(200)
          )
        ),
        composite_score: nil
      )
      automated_metric.save!
    end

    def record_quality_metric
      scores = build_scores
      weights = QualityMetric::GOAL_WEIGHTS.fetch(agent_run.goal, QualityMetric::SCORE_WEIGHTS)
      automated_metric.assign_attributes(
        prompt_version: agent_run.prompt_version,
        feedback_source: "system",
        scores: scores,
        metadata: (automated_metric.metadata || {}).merge(score_metadata),
        composite_score: QualityMetric.weighted_average(scores, weights: weights)
      )
      automated_metric.save!
    end

    def enqueue_quality_gate_check
      return unless agent_run.project.quality_gates_enabled?

      QualityAlerts::CheckGateJob.perform_later(project_id: agent_run.project_id)
    end

    # Builds scores for metrics relevant to the agent run's goal type.
    # `ci_passed`, `tests_pass`, and `pr_merged` are intentionally omitted here:
    # the completion-time agent run does not carry finalized CI/test/merge
    # outcomes, and weighted_average renormalizes over present keys.
    def build_scores
      case agent_run.goal
      when "create_pr" then build_pr_scores
      when "create_issue" then build_issue_scores
      when "review" then build_review_scores
      when "enhance_issue" then build_enhance_issue_scores
      else build_pr_scores
      end
    end

    def build_pr_scores
      scores = {}
      scores["pr_created"] = agent_run.pull_request_number.present? ? 1.0 : 0.0
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

    def build_enhance_issue_scores
      comment_body = enhancement_comment_body
      scores = { "comment_posted" => enhancement_comment_recorded?(comment_body) ? 1.0 : 0.0 }
      return scores if comment_body.blank?

      question_count = count_questions(comment_body)
      score_metadata.merge!(
        "comment_length" => comment_body.length,
        "question_count" => question_count
      )
      scores.merge("question_count" => question_count_score(question_count))
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

      QualityMetric.review_comment_count_score(comment_count)
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

    def enhancement_comment_body
      agent_run.agent_run_logs
        .stdout
        .where("content LIKE ?", "%#{Activities::EnhanceIssueActivity::COMMENT_MARKER}%")
        .recent
        .pick(:content)
        .to_s
    end

    def enhancement_comment_recorded?(comment_body)
      return true if comment_body.present?

      agent_run.agent_run_logs.system
        .where("content LIKE ?", "Enhancement comment already exists:%")
        .exists?
    end

    def count_questions(comment_body)
      question_marks = comment_body.scan("?").size
      numbered_questions = comment_body.lines.count { |line| line.match?(/^\s*\d+[.)]\s+.+\?\s*$/) }

      [ question_marks, numbered_questions ].max
    end

    def question_count_score(question_count)
      return 0.0 if question_count.zero?

      [ question_count / 3.0, 1.0 ].min.round(4)
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
      variant.total_quality_score = (variant.total_quality_score || BigDecimal(0)) + score_decimal
      variant.avg_quality_score = variant.total_quality_score / variant.sample_count
      variant.save!
    end

    def adjust_variant_aggregates(variant, old_score:, new_score:)
      old_decimal = BigDecimal(old_score.to_s)
      new_decimal = BigDecimal(new_score.to_s)
      variant.total_quality_score = (variant.total_quality_score || BigDecimal(0)) - old_decimal + new_decimal
      variant.avg_quality_score = variant.sample_count.positive? ? variant.total_quality_score / variant.sample_count : nil
      variant.save!
    end

    def update_prompt_version_stats
      pv = agent_run.prompt_version

      stats = QualityMetric.where(prompt_version: pv)
        .automated
        .with_composite_score
        .joins(:agent_run).where(AgentRun.quality_scoreable_sql)
        .pick(Arel.sql("COUNT(DISTINCT agent_run_id), AVG(composite_score)"))

      count, avg = stats
      pv.update_columns(
        usage_count: count.to_i,
        avg_quality_score: avg&.round(2)
      )
    end
  end
end
