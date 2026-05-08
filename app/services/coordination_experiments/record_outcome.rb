# frozen_string_literal: true

module CoordinationExperiments
  class RecordOutcome
    def self.call(...)
      new(...).call
    end

    def initialize(assignment:, task_count:, parallel_execution:, result:)
      @assignment = assignment
      @task_count = task_count
      @parallel_execution = parallel_execution
      @result = result
    end

    def call
      computed = OutcomeMetrics.call(
        task_count: task_count,
        parallel_execution: parallel_execution,
        result: result
      )
      variant = assignment.coordination_experiment_variant

      variant.with_lock do
        assignment.reload
        old_score = assignment.coordination_score

        assignment.update!(
          coordination_score: computed.coordination_score,
          outcome_metrics: computed.metrics,
          outcome_status: "recorded"
        )

        if old_score.present?
          adjust_variant_aggregates(variant, old_score:, new_score: computed.coordination_score)
        else
          add_variant_score(variant, computed.coordination_score)
        end
      end

      computed
    end

    private

    attr_reader :assignment, :task_count, :parallel_execution, :result

    def add_variant_score(variant, score)
      score_decimal = BigDecimal(score.to_s)
      variant.sample_count += 1
      variant.total_coordination_score = (variant.total_coordination_score || BigDecimal("0")) + score_decimal
      variant.avg_coordination_score = variant.total_coordination_score / variant.sample_count
      variant.save!
    end

    def adjust_variant_aggregates(variant, old_score:, new_score:)
      old_decimal = BigDecimal(old_score.to_s)
      new_decimal = BigDecimal(new_score.to_s)
      variant.total_coordination_score = (variant.total_coordination_score || BigDecimal("0")) - old_decimal + new_decimal
      variant.avg_coordination_score = variant.sample_count.positive? ? variant.total_coordination_score / variant.sample_count : nil
      variant.save!
    end
  end
end
