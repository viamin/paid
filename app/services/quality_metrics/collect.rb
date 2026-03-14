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
      return if agent_run.quality_metric.present?

      metric = QualityMetric.create!(
        agent_run: agent_run,
        prompt_version: agent_run.prompt_version,
        iterations_to_complete: agent_run.iterations,
        pr_merged: pr_merged?,
        ci_passed: ci_passed?,
        files_changed: count_files_changed,
        lint_errors: count_lint_errors,
        test_failures: count_test_failures,
        review_comments_count: 0
      )

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

    def ci_passed?
      agent_run.status == "completed"
    end

    def count_files_changed
      logs = agent_run.agent_run_logs.where(log_type: "metric")
        .where("metadata->>'type' = 'files_changed'")
        .last
      logs&.metadata&.dig("count")
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
