# frozen_string_literal: true

module Tools
  # @spec FACET-CONFIDENCE-005
  class ChallengeFacetAssessment < BaseTool
    authorize :update?, ->(args) { facet_for(args.fetch(:facet_id)).feature_intent.project }, policy_class: ProjectPolicy

    def self.tool_name = "challenge_facet_assessment"
    def self.write_operation? = true

    def self.description
      "Record a user's explicit correction of a facet assessment and queue a reassessment."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          facet_id: { type: "integer" }, statement: { type: "string" }, chat_message_id: { type: "integer" },
          supersedes_evidence_id: { type: "integer" }, confirmed: { type: "boolean" }
        }, required: %w[facet_id statement chat_message_id confirmed]
      }
    end

    def perform(facet_id:, statement:, chat_message_id:, confirmed:, supersedes_evidence_id: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to challenge an assessment" unless confirmed

      facet = facet_for(facet_id)
      message = session.messages.where(role: "user").find(chat_message_id)
      result = FeatureIntents::ChallengeFacetAssessment.call(facet:, actor: user, statement:,
        source_reference: "chat-message:#{message.external_id}", supersedes: superseded_evidence(facet, supersedes_evidence_id))
      { evidence_id: result.evidence.id, assessment_id: result.assessment.id, status: result.assessment.status }
    end

    private

    def facet_for(facet_id)
      FeatureIntentFacet.joins(feature_intent: :project).where(projects: { account_id: user.account_id }).find(facet_id)
    end

    def superseded_evidence(facet, evidence_id)
      return if evidence_id.blank?

      facet.evidence.find(evidence_id)
    end
  end
end
