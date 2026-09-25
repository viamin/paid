# frozen_string_literal: true

module AppleVerificationAttempts
  # @spec APPLE-ATTEMPT-011
  # @spec APPLE-ATTEMPT-013
  # Creates the first required completion-verification attempt for an agent
  # run once the guest-execution handoff is available. The caller holds the
  # run lock, making the lookup and creation idempotent across completion
  # retries.
  class EnqueueCompletion
    COMPLETION_GATE = "completion_verification"

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(agent_run:, commit_sha:)
      @agent_run = agent_run
      @commit_sha = commit_sha
    end

    def call
      return unless Schedule.execution_available?
      return unless required_workflow&.required_checks&.any?
      return if commit_sha.blank?

      attempt = find_or_create_attempt
      AppleVerificationAttemptMaintenanceJob.perform_later if attempt.previously_new_record?
      attempt
    end

    private

    attr_reader :agent_run, :commit_sha

    def required_workflow
      @required_workflow ||= agent_run.project.apple_verification_workflow_revisions.approved
        .find_by(lifecycle_gate: COMPLETION_GATE)
    end

    def find_or_create_attempt
      agent_run.project.apple_verification_attempts.find_or_create_by!(
        agent_run:,
        apple_verification_workflow_revision: required_workflow,
        lifecycle_gate: COMPLETION_GATE,
        commit_sha:
      ) do |attempt|
        attempt.assign_attributes(
          account: agent_run.project.account,
          apple_worker_profile: required_workflow.apple_worker_profile,
          source_digest: source_digest,
          retry_number: 0,
          status: "queued"
        )
      end
    end

    def source_digest
      "sha256:#{Digest::SHA256.hexdigest(commit_sha)}"
    end
  end
end
