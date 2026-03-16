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
      metric = QualityMetric.find_or_initialize_by(agent_run: agent_run)
      metric.assign_attributes(
        prompt_version: agent_run.prompt_version,
        iterations_to_complete: agent_run.iterations,
        pr_merged: pr_merged?,
        ci_passed: ci_passed,
        files_changed: count_files_changed,
        lint_errors: count_lint_errors,
        test_failures: count_test_failures,
        review_comments_count: metric.review_comments_count || 0
      )
      metric.save!

      metric.calculate_composite_score!
      update_prompt_version_stats if agent_run.prompt_version.present?
      metric
    end

    private

    attr_reader :agent_run

    def pr_merged?
      return nil unless agent_run.pull_request_number

      issue = agent_run.issue
      return nil unless issue

      issue.pr_review_phase == "merged"
    end

    # Returns nil until a real CI status signal is available.
    # Previously returned agent_run.status == "completed", which conflated
    # run completion with CI success and skewed quality scores.
    def ci_passed
      nil
    end

    # Returns nil — no code currently emits a "files_changed" metric log.
    # This field will be populated once PR diff stats are fetched from the
    # GitHub API during post-run analysis.
    def count_files_changed
      nil
    end

    def count_lint_errors
      agent_run.agent_run_logs
        .where(log_type: "stderr")
        .where("content LIKE ?", "%offense%")
        .count
    end

    def count_test_failures
      agent_run.agent_run_logs
        .where(log_type: "stderr")
        .where("content LIKE ? OR content LIKE ?", "%failure%", "%error%")
        .count
    end

    def update_prompt_version_stats
      pv = agent_run.prompt_version
      metrics = QualityMetric.where(prompt_version: pv).with_scores

      pv.update!(
        usage_count: pv.agent_runs.count,
        avg_quality_score: metrics.average(:quality_score)&.round(2),
        avg_iterations: metrics.average(:iterations_to_complete)&.round(2)
      )
    end
  end
end
