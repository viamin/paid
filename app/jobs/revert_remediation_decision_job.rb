# frozen_string_literal: true

class RevertRemediationDecisionJob < ApplicationJob
  queue_as :maintenance

  def perform(remediation_decision_id, actor_id: nil)
    TenantContext.with_system_access do
      decision = RemediationDecision.find(remediation_decision_id)
      actor = User.find_by(id: actor_id) if actor_id.present?

      AgentRunPatterns::RevertDecision.call(decision: decision, actor: actor)
    end
  end
end
