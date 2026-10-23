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

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, resumed: false)
      end
    end
  end
end
