# frozen_string_literal: true

require "digest"

module AppleVerificationWorkflowRevisions
  # Parses committed `.paid/apple-verification.yml` content and binds the
  # result to the project's current draft workflow revision, resolving an
  # active worker profile compatible with every declared platform, Xcode
  # version constraint, and simulator constraint. Never touches an approved
  # revision; a functional change always lands in a new or updated draft.
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
      xcode_constraints = configuration.profiles.filter_map { |profile| profile.worker.xcode }.uniq
      simulators = configuration.profiles.filter_map { |profile| profile.worker.simulator }.uniq

      profile = @project.account.apple_worker_profiles.where(status: "active").find do |candidate|
        supports_platforms?(candidate, platforms) &&
          supports_xcode?(candidate, xcode_constraints) &&
          supports_simulators?(candidate, simulators)
      end

      return profile if profile

      raise NoCompatibleWorkerProfileError, unsupported_profile_diagnostic(platforms:, xcode_constraints:, simulators:)
    end

    def supports_platforms?(candidate, platforms)
      (platforms - Array(candidate.constraints["platforms"])).empty?
    end

    # A profile advertises the Xcode range its image may run, so binding is
    # only safe when that whole range falls inside every constraint the
    # repository declares; otherwise the mismatch fails here, before
    # provisioning, rather than surfacing at run time.
    def supports_xcode?(candidate, declared_constraints)
      advertised = parse_requirement(candidate.constraints["xcode_version"])
      return false unless advertised

      declared_constraints.all? { |declared| advertised.within?(AppleVerificationWorkers::VersionRequirement.parse(declared)) }
    end

    def supports_simulators?(candidate, simulators)
      (simulators - Array(candidate.constraints["simulator_runtimes"]).map(&:to_s)).empty?
    end

    def parse_requirement(constraint)
      return nil if constraint.blank?

      AppleVerificationWorkers::VersionRequirement.parse(constraint)
    rescue AppleVerificationWorkers::InvalidVersionConstraint
      nil
    end

    def unsupported_profile_diagnostic(platforms:, xcode_constraints:, simulators:)
      requirements = [
        "platforms: #{platforms.join(', ')}",
        *xcode_constraints.map { |constraint| "worker.xcode: #{constraint}" },
        *simulators.map { |simulator| "worker.simulator: #{simulator}" }
      ]
      "no active worker profile supports #{requirements.join('; ')}"
    end
  end
end
