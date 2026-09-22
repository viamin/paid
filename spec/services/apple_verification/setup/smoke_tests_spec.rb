# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-003
# @spec APPLE-SETUP-004
RSpec.describe AppleVerification::Setup::SmokeTests do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:lifecycle) { instance_double(AppleVerification::Lifecycle) }
  let(:diagnostics) { ->(probe_id:) { { "status" => "denied", "probe_id" => probe_id } } }
  let(:smoke_attempt) do
    revision = create(:apple_verification_workflow_revision, project: project, account: account)
    create(:apple_verification_attempt,
      project: project,
      account: account,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile)
  end
  let(:attempt_factory) { ->(agent_run:) { smoke_attempt } }
  let(:summary_kwargs) do
    {
      lifecycle:,
      dispatcher: dispatcher,
      diagnostics:,
      image_digest: "sha256:abcdef1234567890",
      profile_id: "ios-standard",
      project_id: project.id,
      attempt_factory:
    }
  end
  let(:summary) { described_class.call(**summary_kwargs) }

  before do
    project
    TenantContext.with_system_access do
      Project.where(id: project.id).update_all(account_id: account.id)
    end
    allow(lifecycle).to receive_messages(provision: instance_double(ExecutionRunners::RunnerHandle, identifier: "paid-vm-1"), destroy: :noop)
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

    it "records a gap until the approved guest executor ships (issue #3937)" do
      summary
      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:gap)
      expect(dependency.detail).to include("permitted dependency access requires the guest executor")
      expect(dependency.detail).to include("#3937")
    end

    it "exercises the lifecycle provision + destroy path before recording the gap" do
      expect(lifecycle).to receive(:provision).with(
        hash_including(image_id: "sha256:abcdef1234567890", profile_id: "ios-standard")
      ).and_return(instance_double(ExecutionRunners::RunnerHandle, identifier: "paid-vm-1"))
      expect(lifecycle).to receive(:destroy)

      summary
      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:gap)
    end

    it "records a gap when the lifecycle is not configured" do
      summary = described_class.call(**summary_kwargs.merge(lifecycle: nil))

      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:gap)
      expect(dependency.detail).to include("lifecycle is not configured")
    end

    it "records a gap when the project id cannot be resolved" do
      summary = described_class.call(**summary_kwargs.merge(project_id: project.id + 9999))

      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:gap)
      expect(dependency.detail).to include("no Paid project matches project_id")
    end

    it "records a gap when no attempt factory is configured" do
      summary = described_class.call(**summary_kwargs.merge(attempt_factory: nil))

      dependency = summary.results.find { |row| row.scenario_id == "permitted-dependency-access" }
      expect(dependency.status).to eq(:gap)
      expect(dependency.detail).to include("no Apple verification attempt was constructed")
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
      summary = described_class.call(**summary_kwargs.merge(diagnostics: nil))

      isolation = summary.results.find { |row| row.scenario_id == "host-isolation-probes" }
      expect(isolation.status).to eq(:gap)
      expect(isolation.detail).to include("diagnostics endpoint is not configured")
    end

    it "fails when a probe does not return denied" do
      flaky = ->(probe_id:) do
        probe_id == "isolation-keychain" ? { "status" => "exposed" } : { "status" => "denied" }
      end

      summary = described_class.call(**summary_kwargs.merge(diagnostics: flaky))

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
      summary = described_class.call(**summary_kwargs.merge(dispatcher: failing))

      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:failed)
    end

    it "records a gap when the dispatcher is not configured" do
      summary = described_class.call(**summary_kwargs.merge(dispatcher: nil))

      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:gap)
      expect(result.detail).to include("dispatcher is not configured")
    end

    it "fails when the synthesized operations are missing the build outcome key" do
      mixed = ->(**) { AppleVerification::Setup::Smoke::Manifests.synthesize_outcomes(
        [ { "type" => "test", "outcome" => "succeeded" } ],
        "build-test-colormatching-ios"
      ) }
      summary = described_class.call(**summary_kwargs.merge(dispatcher: mixed))

      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:failed)
    end

    it "passes when the synthesize helper reports build and test from operations" do
      synthesized = ->(**) { AppleVerification::Setup::Smoke::Manifests.synthesize_outcomes(
        [ { "type" => "build", "outcome" => "succeeded" }, { "type" => "test", "outcome" => "succeeded" } ],
        "build-test-colormatching-ios"
      ) }
      summary = described_class.call(**summary_kwargs.merge(dispatcher: synthesized))

      result = summary.results.find { |row| row.scenario_id == "build-test-colormatching-ios" }
      expect(result.status).to eq(:passed)
    end
  end

  describe "#launch_succeeded" do
    let(:dispatcher) { ->(**) { { "launch_outcome" => "succeeded" } } }

    it "passes when the smoke iOS app launch outcome is succeeded" do
      summary
      result = summary.results.find { |row| row.scenario_id == "smoke-ios-app-launch" }
      expect(result.status).to eq(:passed)
    end

    it "passes when the synthesize helper extracts launch_app from operations" do
      synthesized = ->(**) { AppleVerification::Setup::Smoke::Manifests.synthesize_outcomes(
        [ { "type" => "launch_app", "outcome" => "succeeded" } ],
        "smoke-ios-app-launch"
      ) }
      summary = described_class.call(**summary_kwargs.merge(dispatcher: synthesized))

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
      summary = described_class.call(**summary_kwargs.merge(dispatcher: empty))

      result = summary.results.find { |row| row.scenario_id == "macos-app-screenshot" }
      expect(result.status).to eq(:failed)
    end

    it "passes when the synthesize helper extracts PNG bytes from a capture operation" do
      synthesized = ->(**) { AppleVerification::Setup::Smoke::Manifests.synthesize_outcomes(
        [ { "type" => "capture", "payload" => { "bytes" => 42_424 } } ],
        "macos-app-screenshot"
      ) }
      summary = described_class.call(**summary_kwargs.merge(dispatcher: synthesized))

      result = summary.results.find { |row| row.scenario_id == "macos-app-screenshot" }
      expect(result.status).to eq(:passed)
    end
  end

  describe "#summary" do
    let(:dispatcher) { ->(**) { {} } }

    it "counts passed, failed, and gap rows" do
      summary
      expect(summary.passed_count).to be >= 1
      expect(summary.failed_count).to be >= 0
      expect(summary.gap_count).to be >= 1
    end

    it "is satisfied only when every scenario passed" do
      satisfied_summary = described_class.call(**summary_kwargs.merge(dispatcher: ->(**) do
        {
          "build_outcome" => "succeeded",
          "test_outcome" => "succeeded",
          "launch_outcome" => "succeeded",
          "artifacts" => { "app_window_png_bytes" => 1024 }
        }
      end))

      # permitted-dependency-access records :gap until the guest executor
      # ships (issue #3937), so the summary is satisfied only once that
      # scenario flips to :passed too.
      expect(satisfied_summary.satisfied?).to be(false)
      expect(satisfied_summary.gap_count).to be >= 1
    end
  end
end
