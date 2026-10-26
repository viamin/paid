# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends one reasoned post-unblinding correction without changing the
    # original blinded label or the report measures derived from it.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
      end

      def call
        @evaluation.with_lock { revise }
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def revise
        return failure("reference judgments must be frozen before recording a correction") unless @evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless @actor&.id == @evaluation.created_by_id

        label = @evaluation.labels.find_by(case_id: @case_id, state: "labeled")
        return failure("case #{@case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already carries a recorded correction") if revisions.key?(@case_id)
        return failure("the cited evidence must be one of #{case_evidence_references.join(', ')}") unless case_evidence_references.include?(cited_evidence_reference)

        return failure(candidate.errors.full_messages.to_sentence) unless candidate.valid?

        @evaluation.update!(report: @evaluation.report.merge("revisions" => revisions.merge(@case_id => revision)))
        FacetConfidence::CloseoutEvaluation::CompileReport.call(evaluation: @evaluation)
        log_revision(label)
        Result.new(success: true, error: nil, label: label)
      end

      def revision
        {
          "verdict" => judgment.fetch(:verdict).presence,
          "intent_band" => judgment.fetch(:intent_band).presence,
          "technical_band" => judgment.fetch(:technical_band).presence,
          "readiness" => judgment.fetch(:readiness).presence,
          "cited_evidence_reference" => cited_evidence_reference,
          "reason" => judgment.fetch(:reason).to_s.strip,
          "recorded_by" => @actor.email,
          "recorded_at" => Time.current.iso8601
        }
      end

      def candidate
        @candidate ||= @evaluation.labels.find_by!(case_id: @case_id).dup.tap do |copy|
          copy.assign_attributes(
            verdict: judgment.fetch(:verdict).presence,
            intent_band: judgment.fetch(:intent_band).presence,
            technical_band: judgment.fetch(:technical_band).presence,
            readiness: judgment.fetch(:readiness).presence,
            cited_evidence_reference: cited_evidence_reference,
            reason: judgment.fetch(:reason).to_s.strip
          )
        end
      end

      def revisions = @evaluation.report.fetch("revisions", {})

      def cited_evidence_reference
        judgment.fetch(:cited_evidence_reference).to_s.strip
      end

      def case_evidence_references
        @evaluation.corpus.find_case(@case_id).fetch("evidence").map { |item| item.fetch("reference") }
      end

      def log_revision(label)
        Rails.logger.info(
          message: "facet_confidence.reference_judgment_revised",
          project_id: @evaluation.project_id,
          facet_confidence_evaluation_id: @evaluation.id,
          case_id: label.case_id,
          actor_user_id: @actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, label: nil)
      end
    end
  end
end
