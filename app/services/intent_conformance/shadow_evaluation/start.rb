# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Starts (or resumes) a solo-maintainer shadow evaluation for one
    # evidence generation: the tuple of project, purpose, and frozen corpus
    # manifest digest. Repeated Start actions reuse the existing evaluation
    # instead of duplicating it; a changed corpus digest starts a NEW
    # generation, visibly superseding the old one rather than mutating it.
    # The policy is explicitly selected — the UI flow only accepts solo and
    # never fabricates a second operator identity.
    # @spec INTENT-CONFORMANCE-ROLLOUT-005
    # @spec INTENT-CONFORMANCE-ROLLOUT-009
    class Start
      Result = Data.define(:success, :error, :evaluation, :resumed) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(project:, actor:, purpose:, policy:, manifest_path:, manifest_commit: nil)
        @project = project
        @actor = actor
        @purpose = purpose
        @policy = policy
        @manifest_path = manifest_path
        @manifest_commit = manifest_commit.to_s
        @corpus = ShadowEvaluationCorpus.new(path: manifest_path, commit: manifest_commit)
      end

      def call
        return failure("the solo policy must be explicitly selected; use the team-policy CLI runbook for team evaluation") unless @policy == "solo"
        return failure("the solo maintainer must be the authenticated operator who starts the evaluation") unless @actor.present?

        shape_error = corpus_shape_error
        return failure(shape_error) if shape_error

        digest = @corpus.content_digest
        existing = IntentConformanceShadowEvaluation.find_by(project: @project, purpose: @purpose, manifest_digest: digest)
        return Result.new(success: true, error: nil, evaluation: existing, resumed: true) if existing

        evaluation = IntentConformanceShadowEvaluation.create!(
          project: @project,
          policy: "solo",
          status: "labeling",
          purpose: @purpose,
          manifest_path: @manifest_path,
          manifest_commit: resolved_manifest_commit,
          manifest_digest: digest,
          solo_maintainer: @actor,
          created_by: @actor
        )
        Result.new(success: true, error: nil, evaluation: evaluation, resumed: false)
      rescue ShadowEvaluationCorpus::MissingManifest => error
        failure(error.message)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      rescue ActiveRecord::RecordNotUnique
        # Two operators starting the same evidence generation concurrently both
        # pass the find_by above; the unique (project, purpose, manifest_digest)
        # index keeps exactly one evaluation, so the loser resumes the winner's
        # row instead of surfacing the index race as a 500 (#4598 review).
        winner = IntentConformanceShadowEvaluation.find_by(project: @project, purpose: @purpose, manifest_digest: digest)
        return failure("an evaluation for this evidence generation already exists; start again to resume it") if winner.nil?

        Result.new(success: true, error: nil, evaluation: winner, resumed: true)
      end

      private

      attr_reader :project, :actor, :purpose, :policy, :manifest_path, :manifest_commit, :corpus

      def resolved_manifest_commit
        return manifest_commit if manifest_commit.present?

        # Best-effort provenance: the current HEAD commit that carries the
        # frozen manifest. The digest is the binding identity, not this label.
        stdout, _stderr, status = Open3.capture3("git", "-C", Rails.root.to_s, "rev-parse", "HEAD")
        status.success? ? stdout.strip : ""
      end

      # The form accepts an operator-supplied manifest path, so the corpus
      # must pass the same shape checks the CLI ledger applies (unique ids,
      # ten cases per stratum, full case identity) before an evaluation can
      # exist; otherwise an under-sized manifest could be labeled, frozen,
      # and reported as if it were a qualifying corpus (#4598 review). The
      # digest pinned at creation keeps the validated content byte-identical
      # through freeze and execution.
      def corpus_shape_error
        ShadowEvaluationLedger.validate_corpus_shape!(corpus.resolved_path)
        nil
      rescue ShadowEvaluationCorpus::MissingManifest, ShadowEvaluationLedger::InvalidLedger => error
        error.message
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, resumed: false)
      end
    end
  end
end
