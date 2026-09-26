# frozen_string_literal: true

module AppleVerificationAttempts
  # Decides whether an approved required workflow blocks an agent run at a lifecycle gate.
  # Draft revisions and advisory checks never block; a failed infrastructure attempt stays
  # pending; only a project failure without an unexpired waiver blocks.
  # @spec APPLE-ATTEMPT-011
  # @spec APPLE-ATTEMPT-012
  # @spec APPLE-ATTEMPT-013
  class GateEnforcement
    INFRASTRUCTURE_CLASSIFICATIONS = %w[capacity_or_quota worker_infrastructure cancellation_or_timeout].freeze

    RequiredVerificationPending = Class.new(StandardError)
    RequiredVerificationFailed = Class.new(StandardError)

    Decision = Data.define(:status, :reason, :attempt, :revision, :gate) do
      def not_required? = status == :not_required
      def pending? = status == :pending
      def satisfied? = status == :satisfied
      def blocked? = status == :blocked
      def enforcing? = pending? || blocked?
    end

    class << self
      # Compatibility entry point for callers at either enforcement gate.
      # Pull-request review has no AgentRun, but it still binds verification
      # to the project and the pull request's current head commit.
      def call(agent_run: nil, pull_request: nil, lifecycle_gate:, project: nil)
        return evaluate(agent_run:, gate: lifecycle_gate) if agent_run
        return evaluate_pull_request(project:, pull_request:, gate: lifecycle_gate) if pull_request && project

        not_required(lifecycle_gate)
      end

      def evaluate(agent_run:, gate:, result_commit: nil)
        revision = binding_revision(agent_run.project, gate)
        return not_required(gate) unless revision
        return not_required(gate) if revision.required_checks.empty?
        return execution_not_released(gate) unless Schedule.execution_available?

        attempt = latest_attempt(agent_run, revision, result_commit)
        return pending(revision, gate, reason: "Required Apple verification has not run for this agent run") unless attempt

        evaluate_attempt(attempt, revision, gate)
      end

      def evaluate_pull_request(project:, pull_request:, gate:)
        revision = binding_revision(project, gate)
        return not_required(gate) unless revision
        return not_required(gate) if revision.required_checks.empty?
        return execution_not_released(gate) unless Schedule.execution_available?

        attempt = latest_pull_request_attempt(project, pull_request.head.sha, revision)
        return pending(revision, gate, reason: "Required Apple verification has not run for this pull request") unless attempt

        evaluate_attempt(attempt, revision, gate)
      end

      private

      def binding_revision(project, gate)
        return nil unless FeatureFlags.enabled?(:apple_verification_workers, project: project)
        return nil if project.apple_verification_mode == "off"

        project.apple_verification_workflow_revisions.approved.where(lifecycle_gate: gate).order(revision: :desc).first
      end

      def latest_attempt(agent_run, revision, result_commit)
        revision.apple_verification_attempts.where(agent_run:, commit_sha: result_commit).order(created_at: :desc, id: :desc).first
      end

      def latest_pull_request_attempt(project, head_sha, revision)
        revision.apple_verification_attempts.where(project:, commit_sha: head_sha).order(created_at: :desc, id: :desc).first
      end

      def evaluate_attempt(attempt, revision, gate)
        case attempt.status
        when "succeeded"
          satisfied(attempt, revision, gate, reason: "Required Apple verification succeeded")
        when "failed"
          evaluate_failure(attempt, revision, gate)
        else
          pending(revision, gate, reason: "Required Apple verification has not completed for this agent run (#{attempt.status})")
        end
      end

      def evaluate_failure(attempt, revision, gate)
        if waived?(attempt)
          satisfied(attempt, revision, gate, reason: "Required Apple verification failure was waived by an administrator")
        elsif INFRASTRUCTURE_CLASSIFICATIONS.include?(attempt.failure_classification)
          pending(revision, gate, reason: "Required Apple verification remains pending after an infrastructure failure (#{attempt.failure_classification})")
        else
          blocked(attempt, revision, gate)
        end
      end

      def waived?(attempt)
        attempt.apple_verification_waivers.any?(&:active?)
      end

      def not_required(gate)
        Decision.new(status: :not_required, reason: "No approved required Apple verification workflow applies to the #{gate} gate", attempt: nil, revision: nil, gate: gate)
      end

      # The guest-execution handoff does not yet deliver source, run the
      # verification, and ingest a terminal result. It is therefore not a
      # released required-workflow capability: enforcing it would park agent
      # runs and PR reviews behind attempts that cannot ever complete. The
      # gate becomes active only with that end-to-end handoff.
      def execution_not_released(gate)
        Decision.new(
          status: :not_required,
          reason: "Apple verification required-workflow enforcement is not released for the #{gate} gate",
          attempt: nil,
          revision: nil,
          gate:
        )
      end

      def pending(revision, gate, reason:)
        Decision.new(status: :pending, reason:, attempt: nil, revision:, gate:)
      end

      def satisfied(attempt, revision, gate, reason:)
        Decision.new(status: :satisfied, reason:, attempt:, revision:, gate:)
      end

      def blocked(attempt, revision, gate)
        classification = attempt.failure_classification
        suffix = classification.present? ? " with classification #{classification}" : " without a classification"

        Decision.new(status: :blocked, reason: "Required Apple verification failed#{suffix}", attempt:, revision:, gate:)
      end
    end
  end
end
