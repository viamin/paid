# frozen_string_literal: true

require "digest"

module ProjectDelegation
  module IntentCheckpoint
    # Groups the material product questions known for a work item into one
    # reviewable checkpoint plan (RDR-080 "Intent checkpoint"). Sources are
    # existing records only — RDR-066 open feature decisions grouped under
    # their recorded design claim, and the RDR-071 lane clarifying questions
    # persisted on the issue — so grouping never duplicates feature approval
    # or confidence assessment. Each group presents the question,
    # recommendation, alternatives, consequences, affected scope, and
    # evidence. Revision tokens live on Revisions, so asking whether anything
    # is material never pays the assessment cost.
    # @spec PROJECT-DELEGATION-002
    class Plan
      Group = Data.define(:key, :question, :recommendation, :alternatives, :consequences,
        :affected_scope, :evidence, :source) do
        def identity
          [ key, Plan.normalize_question(question) ]
        end
      end

      Result = Data.define(:groups, :question_set_digest, :feature_intent) do
        def material? = groups.any?
      end

      # Deterministic consequence text for a decision group: what binding the
      # answer means for delegated work. This is policy prose, not a semantic
      # judgment — the meaning of the question itself stays in the recorded
      # prompt and design claim.
      DECISION_CONSEQUENCES =
        "Settling binds this design claim into the delegated admission; rejecting it keeps the claim a human decision and holds delegated work."

      def self.call(project:, issue:)
        groups = feature_decision_groups(issue) + clarifying_question_groups(issue)

        Result.new(
          groups: groups,
          question_set_digest: digest(groups),
          feature_intent: issue.feature_intent
        )
      end

      # @spec PROJECT-DELEGATION-002 — related questions group under their
      # recorded design claim; unrelated claims stay separate groups.
      def self.feature_decision_groups(issue)
        feature = issue.feature_intent
        return [] unless feature

        feature.feature_intent_decisions.open_decisions.map do |decision|
          Group.new(
            key: "claim:#{stable_key(decision.design_claim)}",
            question: decision.prompt,
            recommendation: recommendation_for(decision),
            alternatives: [],
            consequences: DECISION_CONSEQUENCES,
            affected_scope: decision.design_claim,
            evidence: decision_evidence(decision),
            source: "feature_intent_decision:#{decision.id}"
          )
        end
      end

      def self.clarifying_question_groups(issue)
        Array(issue.needs_input_questions).filter_map do |question|
          payload = ClarifyingQuestions::QuestionPayload.call(question: question)
          next if payload.fetch(:question).blank?

          Group.new(
            key: "clarifying:#{stable_key(payload.fetch(:question))}",
            question: payload.fetch(:question),
            recommendation: payload.fetch(:recommendation),
            alternatives: alternatives_from_choices(payload.fetch(:choices)),
            consequences: payload.fetch(:rationale),
            affected_scope: issue.title,
            evidence: payload.fetch(:evidence_references),
            source: "needs_input_questions"
          )
        end
      end

      # The stated assumption of an inferred decision is its recorded
      # recommendation; an open question carries none until settled.
      def self.recommendation_for(decision)
        return decision.prompt if decision.inferred_decision?

        nil
      end

      def self.decision_evidence(decision)
        references = []
        references << "agent_run:#{decision.source_agent_run_id}" if decision.source_agent_run_id
        references
      end

      def self.alternatives_from_choices(choices)
        return [] unless choices.is_a?(Hash)

        Array(choices[:options]).filter_map { |option| option[:label].presence }.compact
      end

      def self.digest(groups)
        Digest::SHA256.hexdigest(groups.map { |group| group.identity.join("\0") }.sort.join("\n"))
      end

      # Stable, readable group keys: claims and questions keep a short digest
      # of their normalized text so a cosmetic re-render does not open a new
      # checkpoint cycle.
      def self.stable_key(text)
        Digest::SHA256.hexdigest(normalize_question(text))[0, 12]
      end

      # Shared question-text normalization so group identity tolerates
      # whitespace-only edits.
      def self.normalize_question(text)
        text.to_s.gsub(/\s+/, " ").strip.downcase
      end

      private_class_method :feature_decision_groups, :clarifying_question_groups, :recommendation_for,
                           :decision_evidence, :alternatives_from_choices, :digest
    end
  end
end
