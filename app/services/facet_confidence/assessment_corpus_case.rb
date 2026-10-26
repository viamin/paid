# frozen_string_literal: true

module FacetConfidence
  # Materializes one frozen corpus case as production facet records and runs
  # the shipped facet assessment path over it, so a measured corpus outcome
  # comes from the shipped rubric instead of hand-written scores.
  #
  # The records exist only inside a rolled-back transaction: a corpus
  # measurement must never reach the readiness path or leave synthetic tenant
  # data behind. The rubric, the prompt contract, the model request, and the
  # response validation are the shipped assessor, not a reimplementation.
  #
  # @spec FACET-CONFIDENCE-022
  class AssessmentCorpusCase
    Outcome = Data.define(:case_id, :status, :intent_score, :technical_score, :evidence_references,
      :served_model, :cost_cents, :failure_reason, :input_revision) do
      def failed? = failure_reason.present?
    end

    # Corpus roles that stand for a person. The harness records them as local
    # identities inside the rolled-back transaction, so the assessment sees
    # attributable human evidence without borrowing a real person's identity.
    # Agent-authored statements stay unattributed: their source type already
    # marks them as agent suggestions.
    HUMAN_ROLES = %w[owner collaborator].freeze

    def self.call(...) = new(...).call

    def initialize(corpus_case:, project:, agent_harness: AgentHarness)
      @corpus_case = corpus_case
      @project = project
      @agent_harness = agent_harness
    end

    def call
      outcome = nil
      ActiveRecord::Base.transaction do
        assessment = build_assessment
        FeatureIntents::AssessFacet.call(assessment: assessment, agent_harness: recording_harness)
        outcome = outcome_for(assessment)
        raise ActiveRecord::Rollback
      end
      outcome
    rescue StandardError => error
      # One case must not abort the corpus: an unexpected failure is recorded
      # as an operational failure with its reason, never as a verdict.
      failed_outcome(error)
    end

    private

    attr_reader :corpus_case, :project, :agent_harness

    def failed_outcome(error)
      Outcome.new(
        case_id: corpus_case.fetch("id"), status: "failed", intent_score: nil, technical_score: nil,
        evidence_references: [], served_model: served_model, cost_cents: cost_cents,
        failure_reason: "#{error.class}: #{error.message}", input_revision: corpus_case.fetch("evidence_revision")
      )
    end

    def outcome_for(assessment)
      Outcome.new(
        case_id: corpus_case.fetch("id"),
        status: assessment.status,
        intent_score: assessment.intent_score,
        technical_score: assessment.technical_score,
        evidence_references: Array(assessment.evidence_references),
        served_model: served_model,
        cost_cents: cost_cents,
        failure_reason: failure_reason_for(assessment),
        input_revision: assessment.evidence_revision
      )
    end

    def failure_reason_for(assessment)
      return nil unless assessment.status == "failed"

      assessment.explanation
    end

    # The model the provider actually served, not the model that was
    # requested: a run may only be attributed to the frozen corpus when the
    # served model is the pinned rubric model.
    def served_model = recording_harness.response&.model

    # Cost provenance is optional harness metadata; 0 means the run measured
    # no cost rather than a cost of zero.
    def cost_cents
      metadata = recording_harness.response&.metadata || {}
      cost = metadata[:cost_cents] || metadata["cost_cents"]
      cost.is_a?(Numeric) ? cost.to_i : 0
    end

    def recording_harness = @recording_harness ||= RecordingHarness.new(agent_harness)

    def build_assessment
      feature_intent = FeatureIntent.create!(project: project, title: "Corpus harness #{facet_name}",
        brief: "Synthetic record for a frozen corpus measurement.", status: "discovering",
        criteria_clarity_state: "pending", delivery_policy: project.feature_delivery_policy_for_new_features)
      facet = FeatureIntentFacet.create!(account: account, feature_intent: feature_intent,
        name: facet_name, design_claim: design_claim)
      direction = FeatureIntentFacetDirection.create!(account: account, feature_intent_facet: facet,
        name: direction_name, description: direction_description)
      ingest_evidence(facet, direction)
      FeatureIntentFacetAssessment.create!(account: account, feature_intent_facet_direction: direction,
        evidence_revision: facet.evidence_revision, status: "pending",
        rubric_version: FeatureIntents::AssessFacet::RUBRIC_VERSION,
        model_version: FeatureIntents::AssessFacet::MODEL_VERSION)
    end

    # The evidence revision advances once per accepted statement, exactly as
    # the ingest path does, so the assessed input revision matches the frozen
    # corpus revision the ledger binds a run to.
    def ingest_evidence(facet, direction)
      records = corpus_case.fetch("evidence").each_with_index.map do |item, index|
        FeatureIntentFacetEvidence.create!(account: account, feature_intent_facet: facet,
          feature_intent_facet_direction: direction, source_type: item.fetch("source_type"),
          source_reference: item.fetch("reference"), idempotency_key: idempotency_key(item),
          statement: item.fetch("statement"), occurred_at: Time.iso8601(item.fetch("occurred_at")),
          evidence_revision: index + 1, textual_context: "corpus actor_role: #{item['actor_role']}",
          actor: harness_actor(item["actor_role"]))
      end
      facet.update!(evidence_revision: records.length)
      link_supersessions(records)
      records
    end

    def link_supersessions(records)
      by_reference = records.index_by(&:source_reference)
      corpus_case.fetch("evidence").each do |item|
        superseded = by_reference[item["supersedes"]] if item["supersedes"]
        superseded&.update!(superseded_by: by_reference.fetch(item.fetch("reference")))
      end
    end

    def idempotency_key(item)
      "corpus-#{corpus_case.fetch('id')}-#{item.fetch('reference')}"
    end

    def harness_actor(role)
      return nil unless HUMAN_ROLES.include?(role.to_s)

      @harness_actors ||= {}
      @harness_actors[role] ||= account.users.create!(
        email: "corpus-harness-#{corpus_case.fetch('id')}-#{role}@example.invalid",
        name: "Corpus #{role}", password: harness_password, password_confirmation: harness_password
      )
    end

    def harness_password = @harness_password ||= SecureRandom.hex(16)

    def account = project.account
    def facet = corpus_case.fetch("facet")
    def facet_name = facet.fetch("name")
    def design_claim = facet.fetch("design_claim")
    def direction = corpus_case.fetch("direction")
    def direction_name = direction.fetch("name")
    def direction_description = direction.fetch("description")

    # Captures the harness response so the runner can read the model the
    # provider actually served and the cost provenance it reported.
    class RecordingHarness
      attr_reader :response

      def initialize(delegate)
        @delegate = delegate
      end

      def send_message(prompt, **options)
        @response = @delegate.send_message(prompt, **options)
      end
    end
  end
end
