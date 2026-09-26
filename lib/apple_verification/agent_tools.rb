# frozen_string_literal: true

require "digest"

module AppleVerification
  # Project-bound semantic operations exposed to paid-agents. Agents may
  # submit source, run draft or approved workflows on demand, inspect
  # structured verification state, and cancel their own active attempts;
  # they cannot approve workflows, enable automatic mode, alter network
  # policy, select privileged images, create waivers, or exceed quotas.
  # @spec APPLE-RESULT-006
  module AgentTools
    MAX_ATTEMPTS_PER_RUN = 3
    ADVISORY_GATE = "agent_iteration"
    SHA256_PATTERN = /\Asha256:[a-f0-9]{64}\z/
    COMMIT_SHA_PATTERN = /\A[0-9a-f]{40}\z/

    CapabilityDisabledError = Class.new(StandardError)
    ModeUnavailableError = Class.new(StandardError)
    AuthorityError = Class.new(StandardError)
    WorkflowUnavailableError = Class.new(StandardError)
    InvalidSourceError = Class.new(ArgumentError)
    QuotaExceededError = Class.new(StandardError)
    CaptureNotDeclaredError = Class.new(StandardError)

    Request = Data.define(:revision, :source_digest, :commit_sha)

    class << self
      def verify_apple_project(project:, agent_run:, bundle_digest: nil, commit_sha: nil)
        request = resolve_request(project:, agent_run:, bundle_digest:, commit_sha:)
        attempt = create_attempt(project:, agent_run:, request:)
        {
          "status" => "queued",
          "attempt_id" => attempt.id,
          "lifecycle_gate" => attempt.lifecycle_gate,
          "workflow_revision_status" => request.revision.status,
          "source_digest" => attempt.source_digest,
          "commit_sha" => attempt.commit_sha,
          "agent_run_id" => agent_run.id
        }
      end

      def capture_apple_screenshot(project:, agent_run:, capture_id:, bundle_digest: nil, commit_sha: nil)
        raise ArgumentError, "capture_id is required" if capture_id.blank?

        request = resolve_request(project:, agent_run:, bundle_digest:, commit_sha:)
        ensure_declared_capture!(request.revision, capture_id)
        attempt = create_attempt(project:, agent_run:, request:, requested_capture: capture_id)
        {
          "status" => "queued",
          "attempt_id" => attempt.id,
          "requested_capture" => capture_id,
          "lifecycle_gate" => attempt.lifecycle_gate,
          "workflow_revision_status" => request.revision.status,
          "agent_run_id" => agent_run.id
        }
      end

      def get_apple_verification(project:, agent_run:, attempt_id: nil)
        ensure_capability(project)
        ensure_mode_available(project)
        ensure_project_match(project, agent_run)

        attempts = project.apple_verification_attempts.where(agent_run: agent_run)
        attempts = attempts.where(id: attempt_id) if attempt_id

        {
          "mode" => project.apple_verification_mode,
          "flag_enabled" => true,
          "workflow" => workflow_summaries(project),
          "attempts" => attempts.order(created_at: :desc, id: :desc)
            .includes(:apple_verification_artifacts, :apple_verification_workflow_revision)
            .map { |attempt| attempt_state(attempt) }
        }
      end

      def stop_apple_verification(project:, agent_run:, attempt_id:)
        ensure_capability(project)
        ensure_mode_available(project)
        ensure_project_match(project, agent_run)

        attempt = project.apple_verification_attempts.find_by(id: attempt_id)
        raise AuthorityError, "attempt not found for this project" if attempt.nil?
        raise AuthorityError, "attempt belongs to a different agent run" unless attempt.agent_run_id == agent_run.id

        AppleVerificationAttempts::Cancel.call(attempt: attempt)
        { "status" => "cancelled", "attempt_id" => attempt.id }
      end

      private

      def resolve_request(project:, agent_run:, bundle_digest:, commit_sha:)
        ensure_capability(project)
        ensure_trigger_mode(project)
        ensure_project_match(project, agent_run)
        raise AuthorityError, "agent run is not active" unless agent_run.active?

        source_digest, committed_sha = resolve_source(bundle_digest:, commit_sha:)
        revision = resolve_revision(project, committed: !committed_sha.nil?)
        ensure_quota(project, agent_run)
        Request.new(revision: revision, source_digest: source_digest, commit_sha: committed_sha)
      end

      def ensure_capability(project)
        unless FeatureFlags.enabled?(:apple_verification_workers, project: project)
          raise CapabilityDisabledError, "the apple_verification_workers rollout flag is disabled for this project"
        end
      end

      def ensure_trigger_mode(project)
        case project.apple_verification_mode
        when "off"
          raise ModeUnavailableError, "Apple verification is off for this project"
        when "automatic"
          raise ModeUnavailableError, "Apple verification mode automatic is scheduler-owned; agents cannot trigger verification"
        end
      end

      def ensure_mode_available(project)
        return unless project.apple_verification_mode == "off"

        raise ModeUnavailableError, "Apple verification is off for this project"
      end

      def ensure_project_match(project, agent_run)
        raise AuthorityError, "agent run belongs to a different project" if agent_run.project_id != project.id
      end

      def resolve_source(bundle_digest:, commit_sha:)
        if bundle_digest.present?
          unless bundle_digest.match?(SHA256_PATTERN)
            raise InvalidSourceError, "bundle_digest must be a sha256:<64 hex> content digest"
          end

          return [ bundle_digest, nil ]
        end

        if commit_sha.blank?
          raise InvalidSourceError, "a source reference is required: pass bundle_digest or commit_sha"
        end
        unless commit_sha.match?(COMMIT_SHA_PATTERN)
          raise InvalidSourceError, "commit_sha must be a 40-character hexadecimal git commit identity"
        end

        [ "sha256:#{Digest::SHA256.hexdigest("commit:#{commit_sha}")}", commit_sha ]
      end

      def resolve_revision(project, committed:)
        if committed
          revision = project.apple_verification_workflow_revisions.approved.order(revision: :desc).first
          raise WorkflowUnavailableError, "no approved workflow revision exists for committed source" unless revision

          return revision
        end

        revision = project.apple_verification_workflow_revisions.where(status: "draft", lifecycle_gate: ADVISORY_GATE).order(revision: :desc).first
        raise WorkflowUnavailableError, "no draft workflow revision exists at the agent_iteration gate for uncommitted source" unless revision

        revision
      end

      def ensure_quota(project, agent_run)
        attempts = project.apple_verification_attempts.where(agent_run: agent_run)
        if attempts.where.not(status: AppleVerificationAttempt::TERMINAL_STATES).exists?
          raise QuotaExceededError, "an active Apple verification attempt already exists for this agent run"
        end
        return unless attempts.count >= MAX_ATTEMPTS_PER_RUN

        raise QuotaExceededError, "agent run exceeded the quota of #{MAX_ATTEMPTS_PER_RUN} Apple verification attempts"
      end

      def ensure_declared_capture!(revision, capture_id)
        declared = revision.required_checks + revision.advisory_checks
        return if capture_id.in?(declared)

        raise CaptureNotDeclaredError, "capture #{capture_id} is not declared by the workflow revision"
      end

      def create_attempt(project:, agent_run:, request:, requested_capture: nil)
        attempt = project.apple_verification_attempts.create!(
          account: project.account,
          agent_run: agent_run,
          apple_verification_workflow_revision: request.revision,
          apple_worker_profile: request.revision.apple_worker_profile,
          source_digest: request.source_digest,
          commit_sha: request.commit_sha,
          requested_capture: requested_capture,
          lifecycle_gate: request.revision.lifecycle_gate,
          retry_number: 0,
          status: "queued"
        )
        AppleVerificationAttempts::Queue.new.enqueue(attempt:)
        attempt
      rescue ActiveRecord::RecordNotUnique
        # Backstop for the check-then-create race in ensure_quota: the partial
        # unique index on active attempts per agent run rejects the second
        # concurrent insert, which must surface as the same quota error.
        raise QuotaExceededError, "an active Apple verification attempt already exists for this agent run"
      end

      def workflow_summaries(project)
        project.apple_verification_workflow_revisions
          .group_by(&:status)
          .transform_values { |revisions| revision_state(revisions.max_by(&:revision)) }
      end

      def revision_state(revision)
        {
          "revision" => revision.revision,
          "content_digest" => revision.content_digest,
          "lifecycle_gate" => revision.lifecycle_gate,
          "required_checks" => revision.required_checks,
          "advisory_checks" => revision.advisory_checks,
          "status" => revision.status
        }
      end

      # @spec APPLE-VERIFY-003
      def attempt_state(attempt)
        revision = attempt.apple_verification_workflow_revision
        {
          "attempt_id" => attempt.id,
          "status" => attempt.status,
          "failure_classification" => attempt.failure_classification,
          "lifecycle_gate" => attempt.lifecycle_gate,
          "source_digest" => attempt.source_digest,
          "commit_sha" => attempt.commit_sha,
          "requested_capture" => attempt.requested_capture,
          "retry_number" => attempt.retry_number,
          "workflow_revision_status" => revision.status,
          "required_checks" => revision.required_checks,
          "advisory_checks" => revision.advisory_checks,
          "created_at" => attempt.created_at&.iso8601,
          "finished_at" => attempt.finished_at&.iso8601,
          "artifacts" => attempt.apple_verification_artifacts.map { |artifact| artifact_state(artifact) }
        }
      end

      # @spec APPLE-VERIFY-004
      def artifact_state(artifact)
        {
          "kind" => artifact.kind,
          "storage_key" => artifact.storage_key,
          "content_type" => artifact.content_type,
          "expires_at" => artifact.expires_at&.iso8601
        }
      end
    end
  end
end
