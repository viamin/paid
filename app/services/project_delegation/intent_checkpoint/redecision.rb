# frozen_string_literal: true

module ProjectDelegation
  class IntentCheckpoint
    # @spec PROJECT-DELEGATION-002
    class Redecision
      def self.call(...) = new(...).call

      def initialize(checkpoint:, design_revision:, acceptance_revision:, account: checkpoint.feature_intent.project.account)
        @checkpoint, @design_revision, @acceptance_revision, @account = checkpoint, design_revision, acceptance_revision, account
      end

      def call
        return if checkpoint.current_binding?(design_revision:, acceptance_revision:)

        Automation::FocusedDecision.call(
          account:, subject: checkpoint.feature_intent, source: "project_delegation.intent_checkpoint",
          title: "Reconsider settled intent checkpoint",
          description: "New design or acceptance evidence differs from the settled intent checkpoint.",
          # String keys match FocusedDecision's persisted metadata identity;
          # symbol keys would never compare equal, defeating its dedup.
          metadata: {
            "authorization_id" => checkpoint.id.to_s,
            "boundary" => "intent_checkpoint",
            "reasons" => { "design_revision" => design_revision, "acceptance_revision" => acceptance_revision }
          }
        )
      end

      private

      attr_reader :account, :acceptance_revision, :checkpoint, :design_revision
    end
  end
end
