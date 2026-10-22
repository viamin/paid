# frozen_string_literal: true

# @spec RUN-OBSTACLE-004
class ApplyRemediationDecisionJob < ApplicationJob
  queue_as :maintenance

  def perform(remediation_decision_id, actor_id: nil)
    TenantContext.with_system_access do
      decision = RemediationDecision.find(remediation_decision_id)
      actor = User.find_by(id: actor_id) if actor_id.present?

      AgentRunPatterns::ApplyDecision.call(decision: decision, applied_by: actor)
    end
  end
end
