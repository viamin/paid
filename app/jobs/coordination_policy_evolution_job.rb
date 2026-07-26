# frozen_string_literal: true

# Weekly cron job that triggers coordination policy evolution workflows for
# eligible accounts.
#
# Runs weekly and evaluates each account with sufficient coordination
# decision history. For each eligible account and policy type, starts a
# CoordinationPolicyEvolutionWorkflow via Temporal to analyze decision patterns,
# generate policy mutations, and create draft CoordinationPolicyVersion records
# for human review.
#
# Skips accounts that already have a running coordination experiment, since
# evolution candidates should not be generated while an active experiment is
# in flight for the same account.
#
# Policy versions are created in draft status and require human approval before
# activation (approval_state: {required: true, status: "pending_review"}).
# This is intentional: automated evolution proposes candidates; human operators
# decide which version to activate via CoordinationPolicy#activate_version!.
class CoordinationPolicyEvolutionJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(total_limit: 1)

  # Policy types to evolve in each weekly run.
  POLICY_TYPES = CoordinationPolicyEvolution::PrepareInputs::SUPPORTED_POLICY_TYPES.freeze

  # Minimum decisions required in the lookback window before a policy type
  # is considered for evolution.
  MIN_DECISIONS = CoordinationPolicyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS

  # Lookback window (days) for sampling coordination decisions.
  LOOKBACK_DAYS = CoordinationPolicyEvolution::PrepareInputs::DEFAULT_LOOKBACK_DAYS

  def perform(account_id: nil, policy_type: nil)
    @account_id = account_id
    @policy_type = policy_type

    policy_types_to_evolve.each do |type|
      eligible_accounts_for(type).find_each do |account|
        start_evolution_workflow(account, type)
      rescue => e
        Rails.logger.warn(
          message: "coordination_policy_evolution.job_failed_for_account",
          account_id: account.id,
          policy_type: type,
          error_class: e.class.name,
          error: e.message
        )
      end
    end
  end

  private

  attr_reader :account_id, :policy_type

  def policy_types_to_evolve
    policy_type ? [ policy_type ] : POLICY_TYPES
  end

  def eligible_accounts_for(type)
    scope = Account
      .where.not(id: accounts_with_running_experiments)
      .where(id: account_ids_with_sufficient_decisions_for(type))

    scope = scope.where(id: account_id) if account_id
    scope
  end

  def accounts_with_running_experiments
    CoordinationExperiment.running.select(:account_id)
  end

  # Returns an array of account IDs with enough coordination decisions in the
  # lookback window for the given policy type. Using pluck avoids a subquery
  # aliasing mismatch when the decision table is joined through projects.
  def account_ids_with_sufficient_decisions_for(type)
    if type == "decomposition"
      DecompositionDecision
        .joins(:project)
        .where(decision_type: DecompositionDecision::POLICY_OUTCOME_DECISION_TYPES)
        .where(created_at: LOOKBACK_DAYS.days.ago..)
        .group("projects.account_id")
        .having("COUNT(*) >= ?", MIN_DECISIONS)
        .pluck("projects.account_id")
    else
      OrchestrationDecision
        .joins(:project)
        .where(actor: orchestration_actor_for(type))
        .where(created_at: LOOKBACK_DAYS.days.ago..)
        .group("projects.account_id")
        .having("COUNT(*) >= ?", MIN_DECISIONS)
        .pluck("projects.account_id")
    end
  end

  def orchestration_actor_for(type)
    case type
    when "recovery" then "coordination_failure_recovery"
    when "escalation" then "coordination_escalation_service"
    else raise ArgumentError, "unsupported orchestration policy type: #{type.inspect}"
    end
  end

  def start_evolution_workflow(account, type)
    workflow_id = "coordination-policy-evolution-#{account.id}-#{type}-#{Date.current}"

    Paid.temporal_client.start_workflow(
      Workflows::CoordinationPolicyEvolutionWorkflow,
      {
        account_id: account.id,
        policy_type: type,
        lookback_days: LOOKBACK_DAYS
      },
      id: workflow_id,
      task_queue: Paid.agent_task_queue
    )

    Rails.logger.info(
      message: "coordination_policy_evolution.workflow_started",
      account_id: account.id,
      policy_type: type,
      workflow_id: workflow_id
    )
  end
end
