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
      metric = QualityMetric.find_or_initialize_by(
        agent_run: agent_run,
        metric_type: "automated"
      )
      metric.assign_attributes(
        prompt_version: agent_run.prompt_version,
        feedback_source: "system",
        scores: build_scores
      )
      metric.save!

      metric.calculate_composite_score!
      update_ab_test_variant_stats(metric)
      update_prompt_version_stats if agent_run.prompt_version.present?
      metric
    end

    private

    attr_reader :agent_run

    def build_scores
      scores = {}
      scores["pr_created"] = agent_run.pull_request_number.present? ? 1.0 : 0.0
      scores["pr_merged"] = pr_merged_score unless pr_merged_score.nil?
      scores["iterations"] = iteration_score if agent_run.iterations&.positive?
      scores["lint_clean"] = lint_clean_score
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

    def lint_clean_score
      has_lint_errors = agent_run.agent_run_logs
        .where(log_type: "stderr")
        .where("content ~ ?", "[1-9][0-9]* offense")
        .exists?

      has_lint_errors ? 0.0 : 1.0
    end

    def update_ab_test_variant_stats(metric)
      assignment = agent_run.ab_test_assignment
      return unless assignment

      assignment.ab_test_variant.record_quality_score!(metric.composite_score)
    end

    def update_prompt_version_stats
      pv = agent_run.prompt_version
      metrics = QualityMetric.where(prompt_version: pv).with_composite_score

      pv.update!(
        usage_count: pv.agent_runs.count,
        avg_quality_score: metrics.average(:composite_score)&.round(2)
      )
    end
  end
end
