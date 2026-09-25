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
      # Compatibility entry point for gate callers that do not yet carry a
      # result commit. Pull-request review has no AgentRun to bind, so it is
      # outside the commit-bound completion gate.
      def call(agent_run: nil, pull_request: nil, lifecycle_gate:, project: nil)
        return evaluate(agent_run:, gate: lifecycle_gate) if agent_run

        not_required(lifecycle_gate)
      end

      def evaluate(agent_run:, gate:, result_commit: nil)
        revision = binding_revision(agent_run.project, gate)
        return not_required(gate) unless revision
        return not_required(gate) if revision.required_checks.empty?

        attempt = latest_attempt(agent_run, revision, result_commit)
        return pending(revision, gate, reason: "Required Apple verification has not run for this agent run") unless attempt

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
