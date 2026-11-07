# frozen_string_literal: true

module PostDeployChecks
  # The only checks Paid will run through PostDeployChecks::Run. Adding a
  # check here is a reviewed code change, never an operator- or
  # caller-supplied string — see docs/intent/post-deploy-measurement.
  # @spec POST-DEPLOY-CHECK-002
  class Registry
    ALLOWLIST = {
      Checks::ClosedAgentPlanningHoldReconciliationCount::KEY => Checks::ClosedAgentPlanningHoldReconciliationCount
    }.freeze

    def self.fetch(check_key)
      ALLOWLIST.fetch(check_key.to_s) { raise UnknownCheckError, "#{check_key} is not an allowlisted post-deploy check" }
    end
  end
end
