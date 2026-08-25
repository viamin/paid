# frozen_string_literal: true

module AgentRuns
  module Research
    class AccessPolicy
      # @spec EGRESS-POLICY-008
      def self.allow!(agent_run:)
        snapshot = agent_run.egress_policy_snapshot
        return if snapshot.is_a?(Hash) && snapshot["egress_profile"] == "research"

        raise ForbiddenError
      end
    end
  end
end
