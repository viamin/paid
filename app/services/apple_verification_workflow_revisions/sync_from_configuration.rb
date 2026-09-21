# frozen_string_literal: true

require "digest"

module AppleVerificationWorkflowRevisions
  # Parses committed `.paid/apple-verification.yml` content and binds the
  # result to the project's current draft workflow revision. Never touches an
  # approved revision; a functional change always lands in a new or updated
  # draft.
  # @spec APPLE-WORKER-013
  class SyncFromConfiguration
    NoCompatibleWorkerProfileError = Class.new(StandardError)

    def self.call(project:, content:, lifecycle_gate: AppleVerificationWorkflowRevision::LIFECYCLE_GATES.first)
      new(project:, content:, lifecycle_gate:).call
    end

    def initialize(project:, content:, lifecycle_gate:)
      @project = project
      @content = content
      @lifecycle_gate = lifecycle_gate
    end

    def call
      configuration = AppleVerification::ConfigurationParser.call(content: @content)
      digest = "sha256:#{Digest::SHA256.hexdigest(@content)}"

      attributes = {
        account: @project.account,
        apple_worker_profile: compatible_worker_profile(configuration),
        content_digest: digest,
        verification_files: [ { "path" => AppleVerification::ConfigurationParser::CONFIG_PATH, "digest" => digest } ],
        lifecycle_gate: @lifecycle_gate,
        required_checks: configuration.required_checks,
        advisory_checks: configuration.advisory_checks
      }

      if (draft = current_draft)
        draft.update!(**attributes)
        draft
      else
        @project.apple_verification_workflow_revisions.create!(revision: next_revision_number, status: "draft", **attributes)
      end
    end

    private

    def current_draft
      @project.apple_verification_workflow_revisions.where(status: "draft").order(revision: :desc).first
    end

    def next_revision_number
      (@project.apple_verification_workflow_revisions.maximum(:revision) || 0) + 1
    end

    def compatible_worker_profile(configuration)
      platforms = configuration.profiles.map(&:platform).uniq
      profile = @project.account.apple_worker_profiles.where(status: "active").find do |candidate|
        (platforms - Array(candidate.constraints["platforms"])).empty?
      end

      return profile if profile

      raise NoCompatibleWorkerProfileError, "no active worker profile supports platforms: #{platforms.join(', ')}"
    end
  end
end
