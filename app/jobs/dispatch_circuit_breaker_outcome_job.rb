# frozen_string_literal: true

class DispatchCircuitBreakerOutcomeJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  # Records a terminal run outcome against the account's dispatch circuit
  # breaker. Runs off the after_commit critical path so that an outage's
  # burst of terminal completions does not each issue a multi-table
  # provider-failure scan inside the activity's commit chain. The breaker
  # service itself serializes evaluations under the row lock, but pushing
  # the call out of the activity's commit handler keeps Temporal activity
  # latency predictable during a tightly-clustered provider outage.
  def perform(account_id:, success:, agent_run_id:)
    account = Account.find(account_id)

    AgentRuns::DispatchCircuitBreaker.record_outcome!(
      account: account,
      success: success,
      agent_run_id: agent_run_id
    )
  end
end
