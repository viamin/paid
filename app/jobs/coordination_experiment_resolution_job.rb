# frozen_string_literal: true

# Periodic job that checks running coordination experiments for completion
# eligibility, selects winners, and marks experiments as completed.
#
# For each running CoordinationExperiment, evaluates whether enough samples
# have been collected and all guardrails pass. If promotion readiness is
# confirmed, the winning variant (highest avg_coordination_score that passes
# guardrails) is recorded on the experiment and the experiment transitions to
# "completed".
#
# Promotion of the winning policy configuration to an active
# CoordinationPolicyVersion is intentionally left as a human-driven step.
# Operators review completed experiments and activate the appropriate
# CoordinationPolicyVersion using CoordinationPolicy#activate_version!.
# This follows the human-review promotion model established by the
# evolution workflow (approval_state: {required: true, auto_promote: false}).
class CoordinationExperimentResolutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(total_limit: 1)

  def perform
    CoordinationExperiment.running.find_each do |experiment|
      resolve_experiment(experiment)
    rescue => e
      Rails.logger.warn(
        message: "coordination_experiment_resolution.failed_for_experiment",
        experiment_id: experiment.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end

  private

  def resolve_experiment(experiment)
    result = CoordinationExperiments::PromotionReadiness.call(
      coordination_experiment: experiment
    )

    case result.status
    when :ready
      experiment.complete!(winner_variant: result.candidate)
      log_completed(experiment, result)
    when :more_data_needed
      log_pending(experiment, result)
    when :guardrail_failed
      log_guardrail_failure(experiment, result)
    when :no_candidate
      log_no_candidate(experiment, result)
    end
  end

  def log_completed(experiment, result)
    Rails.logger.info(
      message: "coordination_experiment_resolution.completed",
      experiment_id: experiment.id,
      winner_variant_id: result.candidate.id,
      candidate_summary: result.candidate_summary,
      control_summary: result.control_summary
    )
  end

  def log_pending(experiment, result)
    Rails.logger.info(
      message: "coordination_experiment_resolution.more_data_needed",
      experiment_id: experiment.id,
      reasons: result.reasons
    )
  end

  def log_guardrail_failure(experiment, result)
    Rails.logger.info(
      message: "coordination_experiment_resolution.guardrail_failed",
      experiment_id: experiment.id,
      reasons: result.reasons,
      candidate_summary: result.candidate_summary,
      control_summary: result.control_summary
    )
  end

  def log_no_candidate(experiment, result)
    Rails.logger.info(
      message: "coordination_experiment_resolution.no_candidate",
      experiment_id: experiment.id,
      reasons: result.reasons
    )
  end
end
