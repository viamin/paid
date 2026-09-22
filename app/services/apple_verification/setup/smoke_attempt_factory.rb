# frozen_string_literal: true

module AppleVerification
  module Setup
    # Builds the per-agent-run +AppleVerificationAttempt+ the smoke
    # scenarios need without touching production workflow revisions.
    #
    # The operator's --profile value (e.g. "ios-standard") is forwarded to
    # the host-side lifecycle.start so the host can address its own
    # profile metadata, but the DB-side +AppleWorkerProfile+ is keyed
    # under a smoke-only name derived from the image digest. The
    # +AppleVerificationWorkflowRevision+ lookup is therefore implicitly
    # scoped to a revision bound to that smoke-only profile, and a draft
    # revision is sufficient because +AppleVerificationAttempt+'s
    # +advisory_draft?+ eligibility check accepts a draft at the
    # +agent_iteration+ lifecycle gate. The factory therefore never
    # invokes the production approval gate, never approves a draft
    # revision the operator did not review, and never collides with a
    # production profile bound to the same project.
    # @spec APPLE-SETUP-007
    class SmokeAttemptFactory
      PROFILE_NAME_PREFIX = "apple-setup-smoke-"
      PROFILE_NAME_DIGEST_FRAGMENT = 12
      SYNTHETIC_CONTENT_DIGEST = "sha256:#{'0' * 64}"
      SMOKE_LIFECYCLE_GATE = "agent_iteration"

      Result = Data.define(:profile, :revision, :attempt)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, image_digest:, profile_id: "ios-standard")
        @project = project
        @image_digest = image_digest
        @profile_id = profile_id
      end

      # Returns a lambda suitable for passing as +attempt_factory:+ to
      # {AppleVerification::Setup::SmokeTests}. The lambda constructs a
      # fresh +AppleVerificationAttempt+ on each invocation so the smoke
      # scenarios get an attempt bound to their individual agent_run while
      # sharing the same smoke-scoped profile + revision across runs.
      def call
        lambda do |agent_run:|
          TenantContext.with_system_access do
            profile = ensure_profile
            revision = ensure_revision(profile)
            Result.new(profile:, revision:, attempt: build_attempt(agent_run:, profile:, revision:))
          end
        end
      end

      private

      attr_reader :project, :image_digest, :profile_id

      def smoke_profile_name
        digest_fragment = image_digest.to_s.delete_prefix("sha256:")[0, PROFILE_NAME_DIGEST_FRAGMENT]
        "#{PROFILE_NAME_PREFIX}#{digest_fragment}"
      end

      def ensure_profile
        AppleWorkerProfile.find_or_create_by!(account: project.account, name: smoke_profile_name) do |profile|
          profile.created_by_id = nil
          profile.image_digest = image_digest
          profile.capabilities = { "capabilities" => %w[build test launch ui_flow screenshot] }
          profile.constraints = { "platforms" => [ "ios" ], "xcode_version" => ">= 26.0, < 27.0" }
        end
      end

      def ensure_revision(profile)
        AppleVerificationWorkflowRevision
          .where(project: project, account: project.account, apple_worker_profile: profile)
          .order(revision: :desc)
          .first || create_revision(profile)
      end

      def create_revision(profile)
        AppleVerificationWorkflowRevision.create!(
          project: project,
          account: project.account,
          apple_worker_profile: profile,
          revision: next_revision_number,
          content_digest: SYNTHETIC_CONTENT_DIGEST,
          verification_files: [
            { "path" => ".paid/apple-verification.yml", "digest" => SYNTHETIC_CONTENT_DIGEST }
          ],
          lifecycle_gate: SMOKE_LIFECYCLE_GATE,
          required_checks: [ "test" ],
          advisory_checks: [ "screenshot" ]
        )
      end

      def next_revision_number
        AppleVerificationWorkflowRevision
          .where(project: project).maximum(:revision).to_i + 1
      end

      def build_attempt(agent_run:, profile:, revision:)
        AppleVerificationAttempt.create!(
          project: project,
          account: project.account,
          apple_verification_workflow_revision: revision,
          apple_worker_profile: profile,
          agent_run: agent_run,
          source_digest: SYNTHETIC_CONTENT_DIGEST,
          lifecycle_gate: revision.lifecycle_gate,
          retry_number: 0
        )
      end
    end
  end
end
