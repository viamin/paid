# frozen_string_literal: true

class RemediationDecisionOutcomeJob < ApplicationJob
  # @spec RUN-OBSTACLE-005
  queue_as :maintenance

  def perform
    TenantContext.with_system_access do
      Account.find_each do |account|
        next unless account.remediation_decisions.pending_outcome.exists?

        AgentRunPatterns::UpdateOutcomes.call(account: account)
      rescue => e
        Rails.logger.warn(
          message: "agent_run_patterns.outcome_update_failed_for_account",
          account_id: account.id,
          error_class: e.class.name,
          error: e.message
        )
      end
    end
  end
end
