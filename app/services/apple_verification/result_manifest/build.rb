# frozen_string_literal: true

module AppleVerification
  module ResultManifest
    # Builds the structured {AppleVerificationWorkers::OutputManifest} for a
    # finished Apple verification attempt (RDR-068 § Results and Artifacts).
    #
    # The manifest composes the attempt identity (source/lineage, workflow
    # revision, lifecycle gate, profile digest), the structured result
    # (status, timings, retry lineage, failure classification, check
    # outcomes, screenshot metadata, network policy mode), and the
    # ingested artifact references (xcresult, build logs, screenshots,
    # diagnostics, and other references). Each artifact reference is a
    # typed object-storage entry scoped to the attempt's namespace.
    #
    # The manifest is validated through {AppleVerificationWorkers::OutputManifest}
    # so a regression that lets a credential, host path, or provider
    # lifecycle field slip in fails closed before it is recorded.
    #
    # @spec APPLE-TRANSFER-004
    class Build
      Result = Data.define(:manifest)

      def self.call(...)
        new(...).call
      end

      def initialize(attempt:, artifact_references: [], audit_event_references: [], ledger_entry_references: [], required_checks: [], advisory_checks: [], screenshot_metadata: [], timings: {})
        @attempt = attempt
        @artifact_references = Array(artifact_references)
        @audit_event_references = Array(audit_event_references)
        @ledger_entry_references = Array(ledger_entry_references)
        @required_checks = Array(required_checks)
        @advisory_checks = Array(advisory_checks)
        @screenshot_metadata = Array(screenshot_metadata)
        @timings = timings || {}
      end

      def call
        manifest = AppleVerificationWorkers::OutputManifest.new(
          attempt: attempt_section,
          result: result_section,
          artifacts: artifacts_section,
          lanes: lanes
        )
        Result.new(manifest: manifest)
      end

      private

      attr_reader :attempt, :artifact_references, :audit_event_references, :ledger_entry_references,
                  :required_checks, :advisory_checks, :screenshot_metadata, :timings

      def attempt_section
        {
          "id" => attempt.id,
          "source_digest" => attempt.source_digest,
          "commit_sha" => attempt.commit_sha,
          "workflow_revision" => workflow_revision_id,
          "lifecycle_gate" => attempt.lifecycle_gate,
          "profile_digest" => profile_digest
        }.compact
      end

      def result_section
        {
          "status" => attempt.status,
          "timings" => timings_payload,
          "retry_lineage" => retry_lineage,
          "failure_classification" => attempt.failure_classification,
          "required_checks" => required_checks.map(&:to_s),
          "advisory_checks" => advisory_checks.map(&:to_s),
          "screenshot_metadata" => screenshot_metadata.map(&:to_s),
          "network_policy" => network_policy_payload,
          "audit_event_references" => audit_event_references.map(&:to_s),
          "ledger_entry_references" => ledger_entry_references.map(&:to_s)
        }.compact
      end

      def artifacts_section
        {
          "xcresult" => artifacts_of_kind("xcresult"),
          "build_logs" => artifacts_of_kind("build_log"),
          "screenshots" => artifacts_of_kind("screenshot"),
          "diagnostics" => artifacts_of_kind("diagnostics"),
          "references" => artifacts_of_kind("manifest")
        }
      end

      def artifacts_of_kind(kind)
        artifact_references.select { |reference| reference["kind"].to_s == kind.to_s }
      end

      def lanes
        {
          "git" => git_lane,
          "control_plane_api" => control_plane_api_lane,
          "object_storage" => object_storage_lane,
          "credentials" => []
        }
      end

      def git_lane
        return [] if attempt.commit_sha.blank?

        [ {
          "lane" => "git",
          "kind" => "git_output",
          "locator" => {
            "repo_full_name" => attempt.project.full_name,
            "commit_sha" => attempt.commit_sha
          }
        } ]
      end

      def control_plane_api_lane
        refs = []
        refs << { "lane" => "control_plane_api", "kind" => "apple_verification_attempt", "locator" => { "attempt_id" => attempt.id } }
        refs.concat(audit_event_references.map { |id| { "lane" => "control_plane_api", "kind" => "execution_audit_event", "locator" => { "audit_event_id" => id } } })
        refs.concat(ledger_entry_references.map { |id| { "lane" => "control_plane_api", "kind" => "execution_resource_ledger_entry", "locator" => { "id" => id } } })
        refs
      end

      def object_storage_lane
        artifact_references
      end

      def timings_payload
        return {} if timings.blank?

        timings.stringify_keys.slice("queued_ms", "provisioning_ms", "running_ms", "total_ms")
      end

      def retry_lineage
        # Walk the +retry_of_attempt_id+ chain to collect only the attempts
        # the current attempt is actually a retry of, plus the attempt itself.
        # The chain encodes a one-to-one retry relationship
        # ({AppleVerificationAttempt#retry_of_attempt}); an unrelated sibling
        # attempt that shares the workflow revision must not appear in the
        # lineage even when its +retry_number+ happens to be lower, which a
        # `retry_number <=` query would otherwise include.
        ids = []
        current = attempt
        while current&.retry_of_attempt_id
          parent = current.retry_of_attempt
          break unless parent
          break if ids.include?(parent.id)

          ids.unshift(parent.id)
          current = parent
        end
        ids << attempt.id
        ids.map(&:to_s)
      end

      def network_policy_payload
        mode = attempt.agent_run&.egress_policy_snapshot
        return nil if mode.blank?

        { "mode" => mode["mode"].to_s, "egress_profile" => mode["egress_profile"].to_s }.compact
      end

      def workflow_revision_id
        attempt.apple_verification_workflow_revision_id
      end

      def profile_digest
        attempt.apple_worker_profile&.image_digest
      end
    end
  end
end
