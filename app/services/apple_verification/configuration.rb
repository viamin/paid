# frozen_string_literal: true

module AppleVerification
  # Typed repository verification configuration parsed from
  # `.paid/apple-verification.yml`.
  # @spec APPLE-WORKER-011
  class Configuration < ::Data.define(:version, :profiles)
    Profile = ::Data.define(:name, :platform, :worker, :xcode, :bootstrap, :tests_required, :captures)
    WorkerConstraint = ::Data.define(:xcode, :simulator)
    XcodeTarget = ::Data.define(:project, :workspace, :scheme, :test_plan)
    Capture = ::Data.define(:id, :required, :flow)
    FlowStep = ::Data.define(:operation, :arguments)

    def required_checks
      checks_by(required: true)
    end

    def advisory_checks
      checks_by(required: false)
    end

    private

    def checks_by(required:)
      profiles.flat_map do |profile|
        [
          (profile.tests_required == required) ? "#{profile.name}.tests" : nil,
          *profile.captures.select { |capture| capture.required == required }.map { |capture| "#{profile.name}.#{capture.id}" }
        ].compact
      end
    end
  end
end
