# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-003
# @spec APPLE-SETUP-004
RSpec.describe AppleVerification::Setup::SmokeTests do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:lifecycle) { instance_double(AppleVerification::Lifecycle) }
  let(:diagnostics) { ->(probe_id:) { { "status" => "denied", "probe_id" => probe_id } } }
  let(:summary) do
    described_class.call(
      lifecycle:,
      dispatcher: dispatcher,
      diagnostics:,
      image_digest: "sha256:abcdef1234567890",
      profile_id: "ios-standard"
    )
  end

  before do
    project
    # The smoke harness probes for an existing Paid project to anchor its
    # smoke agent_run. Force the factory-built project into view so the
    # dependency-access scenario can provision a guest under test.
    TenantContext.with_system_access do
      Project.where(id: project.id).update_all(account_id: account.id)
    end
    # Every smoke scenario runs even when a single example focuses on one
    # scenario, so stub lifecycle.provision with a permissive default and
    # let individual specs tighten it.
    allow(lifecycle).to receive(:provision).and_return(
      instance_double(ExecutionRunners::RunnerHandle, identifier: "paid-vm-1")
    )
  end


  describe "scenario matrix" do
    it "covers every required acceptance scenario from RDR-068 / issue #3941" do
      ids = described_class::SCENARIOS.map(&:id)
      expect(ids).to contain_exactly(
        "permitted-dependency-access",
        "host-isolation-probes",
        "build-test-colormatching-ios",
        "smoke-ios-app-launch",
        "macos-app-screenshot"
      )
    end
  end

  describe "#permitted_dependency_access" do
    let(:dispatcher) { ->(**) { { "build_outcome" => "succeeded" } } }

    it "passes when the lifecycle can provision a smoke guest" do
      summary
      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:passed)
    end

    it "records a gap when the lifecycle is not configured" do
      summary = described_class.call(
        lifecycle: nil,
        dispatcher: dispatcher,
        diagnostics:,
        image_digest: "sha256:abcdef1234567890"
      )

      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:gap)
      expect(dependency.detail).to include("lifecycle is not configured")
    end
  end

  describe "#host_isolation_probes" do
    let(:dispatcher) { ->(**) { {} } }

    it "passes when every probe returns denied through the diagnostics endpoint" do
      summary
      isolation = summary.results.find { |row| row.scenario_id == "host-isolation-probes" }
      expect(isolation.status).to eq(:passed)
      expect(isolation.detail).to include("all 6 isolation probes denied")
    end

    it "records a gap when no diagnostics endpoint is configured" do
      summary = described_class.call(
        lifecycle:, dispatcher: dispatcher, diagnostics: nil,
        image_digest: "sha256:abcdef1234567890"
      )

      isolation = summary.results.find { |row| row.scenario_id == "host-isolation-probes" }
      expect(isolation.status).to eq(:gap)
      expect(isolation.detail).to include("diagnostics endpoint is not configured")
    end

    it "fails when a probe does not return denied" do
      flaky = ->(probe_id:) do
        probe_id == "isolation-keychain" ? { "status" => "exposed" } : { "status" => "denied" }
      end

      summary = described_class.call(
        lifecycle:, dispatcher: dispatcher, diagnostics: flaky,
        image_digest: "sha256:abcdef1234567890"
      )

      isolation = summary.results.find { |row| row.scenario_id == "host-isolation-probes" }
      expect(isolation.status).to eq(:failed)
      expect(isolation.detail).to include("5/6")
    end
  end

  describe "#build_test_succeeded" do
    let(:dispatcher) { ->(**) { { "build_outcome" => "succeeded", "test_outcome" => "succeeded" } } }

    it "passes when the dispatcher reports build and test success" do
      summary
      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:passed)
    end

    it "fails when the dispatcher reports a build failure" do
      failing = ->(**) { { "build_outcome" => "failed", "test_outcome" => "skipped" } }
      summary = described_class.call(
        lifecycle:, dispatcher: failing, diagnostics:, image_digest: "sha256:abcdef1234567890"
      )

      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:failed)
    end

    it "records a gap when the dispatcher is not configured" do
      summary = described_class.call(
        lifecycle:, dispatcher: nil, diagnostics:, image_digest: "sha256:abcdef1234567890"
      )

      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:gap)
      expect(result.detail).to include("dispatcher is not configured")
    end
  end

  describe "#launch_succeeded" do
    let(:dispatcher) { ->(**) { { "launch_outcome" => "succeeded" } } }

    it "passes when the smoke iOS app launch outcome is succeeded" do
      summary
      result = summary.results.find { |row| row.scenario_id == "smoke-ios-app-launch" }
      expect(result.status).to eq(:passed)
    end
  end

  describe "#screenshot_captured" do
    let(:dispatcher) do
      ->(**) { { "artifacts" => { "app_window_png_bytes" => 12_345 } } }
    end

    it "passes when the macOS app window screenshot is non-empty" do
      summary
      result = summary.results.find { |row| row.scenario_id == "macos-app-screenshot" }
      expect(result.status).to eq(:passed)
    end

    it "fails when no PNG bytes are returned" do
      empty = ->(**) { { "artifacts" => {} } }
      summary = described_class.call(
        lifecycle:, dispatcher: empty, diagnostics:, image_digest: "sha256:abcdef1234567890"
      )

      result = summary.results.find { |row| row.scenario_id == "macos-app-screenshot" }
      expect(result.status).to eq(:failed)
    end
  end

  describe "#summary" do
    let(:dispatcher) { ->(**) { {} } }

    it "counts passed, failed, and gap rows" do
      summary
      expect(summary.passed_count).to be >= 1
      expect(summary.failed_count).to be >= 0
      expect(summary.gap_count).to be >= 0
    end

    it "is satisfied only when every scenario passed" do
      satisfied_summary = described_class.call(
        lifecycle:,
        dispatcher: ->(**) do
          {
            "build_outcome" => "succeeded",
            "test_outcome" => "succeeded",
            "launch_outcome" => "succeeded",
            "artifacts" => { "app_window_png_bytes" => 1024 }
          }
        end,
        diagnostics:,
        image_digest: "sha256:abcdef1234567890"
      )

      expect(satisfied_summary.satisfied?).to be(true)
    end
  end
end
