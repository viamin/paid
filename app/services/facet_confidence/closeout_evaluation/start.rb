# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Starts (or resumes) a facet-confidence closeout evaluation for one
    # evidence generation: the tuple of the originating issue and the frozen
    # corpus manifest digest. Repeated Start actions reuse the existing
    # evaluation instead of duplicating it; a changed corpus digest starts a
    # NEW generation, superseding the old one rather than mutating it. The
    # entry point stays blocked while the closeout records unresolved
    # blockers, and the operator who starts becomes the sole reference judge.
    # @spec FACET-CONFIDENCE-020
    class Start
      Result = Data.define(:success, :error, :evaluation, :resumed) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(project:, issue:, actor:, status: nil, entry_notification: nil)
        @project = project
        @issue = issue
        @actor = actor
        @status = status
        @entry_notification = entry_notification
      end

      def call
        return failure("the originating work item must belong to this project") unless @issue.project_id == @project.id
        return failure("an authenticated operator must start the evaluation") if @actor.blank?

        blockers = evaluation_packet.blockers
        return failure("the closeout entry point is blocked until its recorded prerequisites resolve: #{blockers.map { |blocker| blocker.fetch(:message) }.join(' ')}") if blockers.any?

        corpus = FacetConfidence::Corpus.new(path: CloseoutEvaluationPacket::MANIFEST_PATH)
        identity = corpus.identity
        digest = corpus.content_digest
        existing = FacetConfidenceEvaluation.find_by(issue: @issue, corpus_digest: digest)
        return Result.new(success: true, error: nil, evaluation: existing, resumed: true) if existing

        evaluation = FacetConfidenceEvaluation.create!(
          project: @project,
          issue: @issue,
          status: "labeling",
          corpus_path: CloseoutEvaluationPacket::MANIFEST_PATH,
          corpus_digest: digest,
          corpus_version: identity.fetch("corpus_version"),
          rubric_version: identity.fetch("rubric_version"),
          model_version: identity.fetch("model_version"),
          source_revision: PartialCloseouts::Assessment.call(@issue).source_revision,
          created_by: @actor
        )
        log_started(evaluation, resumed: false)
        Result.new(success: true, error: nil, evaluation: evaluation, resumed: false)
      rescue FacetConfidence::Corpus::MissingManifest,
             FacetConfidence::AssessmentCorpusLedger::InvalidLedger => error
        failure(error.message)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      rescue ActiveRecord::RecordNotUnique
        # Two operators starting the same evidence generation concurrently both
        # pass the find_by above; the unique (issue, corpus_digest) index keeps
        # exactly one evaluation, so the loser resumes the winner's row instead
        # of surfacing the index race as a 500.
        winner = FacetConfidenceEvaluation.find_by(issue: @issue, corpus_digest: digest)
        return failure("an evaluation for this evidence generation already exists; start again to resume it") if winner.nil?

        Result.new(success: true, error: nil, evaluation: winner, resumed: true)
      end

      private

      attr_reader :project, :issue, :actor, :status, :entry_notification

      def closeout_status
        @status || Issues::CloseoutStatus.call(@issue)
      end

      def evaluation_packet
        CloseoutEvaluationPacket.call(issue:, status: closeout_status, entry_notification:)
      end

      def log_started(evaluation, resumed:)
        Rails.logger.info(
          message: "facet_confidence.closeout_evaluation_started",
          project_id: @project.id,
          issue_id: @issue.id,
          facet_confidence_evaluation_id: evaluation.id,
          corpus_version: evaluation.corpus_version,
          actor_user_id: @actor.id,
          resumed: resumed
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, resumed: false)
      end
    end
  end
end
