# frozen_string_literal: true

class RemediationDecisionOutcomeJob < ApplicationJob
  queue_as :maintenance

  def perform
    TenantContext.with_system_access do
      Account.find_each do |account|
        patterns = AgentRunPatterns::Detect.call(account: account)
        AgentRunPatterns::UpdateOutcomes.call(account: account, patterns: patterns)
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
