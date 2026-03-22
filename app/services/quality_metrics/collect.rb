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
      scores = build_scores
      metric.assign_attributes(
        prompt_version: agent_run.prompt_version,
        feedback_source: "system",
        scores: scores,
        composite_score: QualityMetric.weighted_average(scores)
      )
      metric.save!

      update_ab_test_variant_stats(metric)
      update_prompt_version_stats if agent_run.prompt_version.present?
      metric
    end

    private

    attr_reader :agent_run

    # Builds scores for metrics that can be reliably determined from available data.
    # `ci_passed` and `tests_pass` are intentionally omitted because the agent run
    # does not track CI/test results separately — the weighted_average method
    # renormalizes over present keys so the composite score remains valid.
    def build_scores
      scores = {}
      scores["pr_created"] = agent_run.pull_request_number.present? ? 1.0 : 0.0
      merged = pr_merged_score
      scores["pr_merged"] = merged unless merged.nil?
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
            variant.record_quality_score!(metric.composite_score)
          end
        end
      end
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
