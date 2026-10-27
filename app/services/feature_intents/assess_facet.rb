# frozen_string_literal: true

module FeatureIntents
  # Runs the semantic facet evaluation at a background boundary. Rails only
  # validates and persists the agent's structured result; it never derives a
  # score from counts or keywords.
  # @spec FACET-CONFIDENCE-002 FACET-CONFIDENCE-003 FACET-CONFIDENCE-004 FACET-CONFIDENCE-017
  # @spec FACET-CONFIDENCE-012 FACET-CONFIDENCE-013 FACET-CONFIDENCE-014
  # @spec LLM-ROUTING-004
  class AssessFacet
    include Llm::OutputNormalizer
    RUBRIC_VERSION = "facet-confidence-v1"
    MODEL_VERSION = "pending"
    TIMEOUT = 60
    STATUSES = %w[completed clarification_needed unknown].freeze

    def self.call(...) = new(...).call

    def initialize(assessment:, agent_harness: AgentHarness)
      @assessment = assessment
      @agent_harness = agent_harness
    end

    attr_reader :cost_cents, :response_status

    def call
      apply(response_payload)
    rescue AgentHarness::Error => e
      fail!(e.class.name)
    end

    private

    attr_reader :agent_harness, :assessment

    def response_payload
      response = Llm::Request.call(prompt: prompt, project: facet.feature_intent.project, timeout: TIMEOUT, harness: agent_harness)
      @response_model = response.respond_to?(:model) ? response.model.presence || "unknown" : "unknown"
      @cost_cents = cost_cents_from(response, @response_model)
      return unless response.respond_to?(:success?) && response.success?

      parsed = JSON.parse(strip_markdown_fence(response.output.to_s))
      parsed.deep_stringify_keys if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def apply(payload)
      assessment.with_lock do
        return supersede! unless current_evidence?
        return fail!("invalid_structured_output") unless valid_payload?(payload)

        @response_status = payload.fetch("status")
        attributes = payload.slice("intent_score", "technical_score", "explanation", "inferred_fit", "evidence_references").merge(
          rubric_version: RUBRIC_VERSION, model_version: @response_model
        )
        if payload["status"] == "completed"
          assessment.update!(attributes.merge(status: "completed", assessed_at: Time.current))
        else
          assessment.update!(attributes.merge(status: "unknown", intent_score: nil,
            explanation: "Clarification needed: #{payload.fetch("explanation")}", assessed_at: Time.current))
        end
        assessment
      end
    end

    def fail!(reason)
      assessment.with_lock do
        return supersede! unless current_evidence?

        assessment.update!(status: "failed", intent_score: nil, technical_score: nil,
          explanation: "Assessment unavailable (#{reason}).", assessed_at: Time.current)
        assessment
      end
    end

    def supersede!
      assessment.update!(status: "superseded", intent_score: nil, technical_score: nil,
        explanation: "Assessment superseded by newer evidence.", assessed_at: Time.current)
      assessment
    end

    # Re-reads both rows under row locks instead of trusting the in-memory
    # instances captured while building the prompt: locking also waits out an
    # ingest transaction that already advanced the revision but has not yet
    # committed. Facet is locked before direction to match the lock order of
    # ChallengeFacetAssessment, so the two cannot deadlock.
    def current_evidence?
      facet.lock!.evidence_revision == assessment.evidence_revision && direction.lock!.status == "active"
    end

    def valid_payload?(payload)
      payload.is_a?(Hash) && payload.keys.sort == %w[evidence_references explanation inferred_fit intent_score status technical_score] &&
        STATUSES.include?(payload["status"]) && valid_explanation?(payload) && valid_inferred_fit?(payload) && valid_references?(payload) && valid_scores?(payload)
    end

    def valid_explanation?(payload) = payload["explanation"].is_a?(String) && payload["explanation"].strip.present?
    def valid_inferred_fit?(payload) = payload["inferred_fit"].nil? || payload["inferred_fit"].is_a?(String)

    def valid_references?(payload)
      references = payload["evidence_references"]
      references.is_a?(Array) && references.present? && references.all? { |reference| active_references.include?(reference) }
    end

    def valid_scores?(payload)
      return known_score?(payload["intent_score"]) && known_score?(payload["technical_score"]) if payload["status"] == "completed"

      payload["intent_score"].nil? && (payload["technical_score"].nil? || known_score?(payload["technical_score"]))
    end

    def known_score?(score) = score.is_a?(Integer) && score.between?(0, 100)
    def direction = assessment.feature_intent_facet_direction
    def facet = direction.feature_intent_facet
    def active_references = @active_references ||= facet.evidence.where(superseded_by: nil).pluck(:source_reference)

    def cost_cents_from(response, model)
      return unless response.respond_to?(:input_tokens) && response.respond_to?(:output_tokens)

      input_tokens = response.input_tokens
      output_tokens = response.output_tokens
      return unless [ input_tokens, output_tokens ].all? { |tokens| tokens.is_a?(Integer) && tokens >= 0 }

      TokenUsageTracker.calculate_cost(input_tokens, output_tokens, llm_model: model)
    end

    def prompt
      <<~PROMPT
        Assess the active candidate direction for this facet using rubric #{RUBRIC_VERSION}.
        Intent certainty measures attributable human direction. Technical confidence measures demonstrated feasibility. They are independent 0-100 integer scores; unknown is null, never a guess.
        Do not count duplicate evidence, UI interactions, or repeated agent suggestions as agreement. An explicit correction supersedes its earlier statement. If collaborators conflict, return clarification_needed instead of selecting a majority.
        Return only JSON with exactly status, intent_score, technical_score, inferred_fit, explanation, evidence_references. inferred_fit is a distinct assessment of the candidate's fit, never a human preference; use null when unknown. status is completed, clarification_needed, or unknown. A completed result requires both scores. Evidence references must be drawn exactly from the supplied active evidence.

        Facet: #{facet.name}
        Design claim: #{facet.design_claim}
        Candidate direction: #{direction.name}: #{direction.description}
        Active evidence: #{JSON.generate(active_evidence)}
      PROMPT
    end

    def active_evidence
      facet.evidence.where(superseded_by: nil).order(:evidence_revision).map do |evidence|
        { reference: evidence.source_reference, source_type: evidence.source_type, statement: evidence.statement,
          occurred_at: evidence.occurred_at.iso8601, actor_id: evidence.actor_id,
          actor_context: evidence.textual_context.presence }.compact
      end
    end
  end
end
