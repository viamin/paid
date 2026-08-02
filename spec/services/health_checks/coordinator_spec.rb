# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Coordinator do
  let(:project) { build_stubbed(:project) }

  describe ".call" do
    it "returns a Result aggregating findings from the scope's checks" do
      result = described_class.call(scope: :project, subject: project, include_network: false)

      expect(result).to be_a(HealthChecks::Result)
      expect(result.findings).to be_an(Array)
      expect(result.checked_at).to be_present
      expect(result.duration_ms).to be_a(Integer)
    end

    it "returns a healthy result when no checks fire" do
      allow(HealthChecks::Checks::Project::EmptyAllowlist).to receive(:call).and_return([])
      allow(HealthChecks::Checks::Project::MissingGitHubCredential).to receive(:call).and_return([])

      result = described_class.call(scope: :project, subject: project)

      expect(result).to be_healthy
    end

    it "includes network checks only when include_network is true" do
      network = HealthChecks::Checks::Project::ReviewBotNotInstalled
      allow(network).to receive(:call).and_return(
        [ HealthChecks::Finding.new(check: network.name, scope: :project, severity: :warning, message: "x") ]
      )

      local_result = described_class.call(scope: :project, subject: project, include_network: false)
      network_result = described_class.call(scope: :project, subject: project, include_network: true)

      expect(local_result.findings).to be_empty
      expect(network_result.findings.map(&:check)).to include(network.name)
    end

    it "turns a raising check into an internal-error finding instead of failing the run" do
      boom = HealthChecks::Checks::Project::EmptyAllowlist
      allow(boom).to receive(:call).and_raise(StandardError, "kaboom")

      result = described_class.call(scope: :project, subject: project)

      error_finding = result.findings.find { |finding| finding.check == boom.name }
      expect(error_finding).not_to be_nil
      expect(error_finding.severity).to eq(:error)
      expect(error_finding.message).to include("kaboom")
      expect(result).not_to be_healthy
    end

    it "composes runner-scope findings for the project's effective owner's agent runners" do
      persisted_project = create(:project)
      create(:runner, user: persisted_project.effective_owner)
      network = HealthChecks::Checks::Runner::DeprecatedModel
      allow(network).to receive(:call).and_return(
        [ HealthChecks::Finding.new(check: network.name, scope: :runner, severity: :warning, message: "stale") ]
      )

      result = described_class.call(scope: :project, subject: persisted_project, include_network: true)

      expect(result.findings.map(&:check)).to include(network.name)
    end

    it "does not compose runner-scope findings when scope is not :project" do
      runner = build_stubbed(:runner)

      result = described_class.call(scope: :runner, subject: runner, include_network: true)

      expect(result.findings.map(&:scope)).to all(eq(:runner))
    end
  end
end
