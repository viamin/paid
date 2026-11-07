# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # The revision tokens a checkpoint binds and every later boundary recheck
    # re-derives. The design revision is the feature's approved design
    # revision (RDR-066) when a feature owns the work item; otherwise the work
    # item's intent-revision digest. The acceptance and evidence revisions
    # reuse the canonical delegated-admission tokens so the checkpoint can
    # never drift from what admission compares.
    # @spec PROJECT-DELEGATION-002
    class Revisions
      # Callers that already resolved the work item's closeout assessment
      # pass it in so a boundary recheck keeps a single assessment query.
      def self.for(issue, assessment: nil)
        tokens = Automation::DelegatedActionAdmission.revision_tokens(
          issue: issue, assessment: assessment || PartialCloseouts::Assessment.call(issue)
        )
        {
          "design_revision" => design_revision_for(issue) || tokens.fetch("intent_revision"),
          "acceptance_revision" => tokens.fetch("acceptance_revision"),
          "evidence_revision" => tokens.fetch("evidence_revision")
        }
      end

      # The feature's approved design revision when one exists and is
      # recorded; nil lets the caller fall back to the intent digest.
      def self.design_revision_for(issue)
        feature = issue.feature_intent
        feature&.approved_design_revision
      end

      private_class_method :design_revision_for
    end
  end
end
