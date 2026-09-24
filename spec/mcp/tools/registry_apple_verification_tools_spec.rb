# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Registry do
  # @spec APPLE-RESULT-006
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:, initiating_user: user) }
  let(:bundle_digest) { "sha256:#{'e' * 64}" }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def draft_revision
    create(
      :apple_verification_workflow_revision,
      project:,
      lifecycle_gate: "agent_iteration",
      required_checks: %w[ios-app.tests],
      advisory_checks: %w[ios-app.initial-screen]
    )
  end

  describe "registry exposure" do
    it "registers the four semantic tools" do
      expect(described_class.find("verify_apple_project")).to eq(Tools::VerifyAppleProject)
      expect(described_class.find("get_apple_verification")).to eq(Tools::GetAppleVerification)
      expect(described_class.find("capture_apple_screenshot")).to eq(Tools::CaptureAppleScreenshot)
      expect(described_class.find("stop_apple_verification")).to eq(Tools::StopAppleVerification)
    end

    it "marks request tools as write operations and state inspection as read-only" do
      expect(Tools::VerifyAppleProject.write_operation?).to be(true)
      expect(Tools::CaptureAppleScreenshot.write_operation?).to be(true)
      expect(Tools::StopAppleVerification.write_operation?).to be(true)
      expect(Tools::GetAppleVerification.write_operation?).to be(false)
    end

    it "exposes the read tool through read-only MCP dispatch" do
      draft_revision

      result = described_class.dispatch_read_only(
        name: "get_apple_verification",
        arguments: { "project_id" => project.id, "agent_run_id" => agent_run.id },
        user:,
        session:,
        agent_run:
      )

      expect(result).to include("mode" => "on_demand")
    end
  end

  describe Tools::VerifyAppleProject do
    let(:tool) { described_class.new(user:, session:, agent_run:) }

    it "queues a verification attempt for the acting agent run" do
      draft_revision

      result = tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest, confirmed: true)

      expect(result).to include("status" => "queued", "lifecycle_gate" => "agent_iteration")
    end

    it "requires explicit confirmation" do
      draft_revision

      expect {
        tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "denies users who cannot run agents on the project" do
      outsider = create(:user)
      outsider_session = create(:chat_session, account:, created_by: outsider)
      outsider_tool = described_class.new(user: outsider, session: outsider_session)
      draft_revision

      expect {
        outsider_tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest, confirmed: true)
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "denies a run owned by another agent" do
      other_user = create(:user, :member, account:)
      other_run = create(:agent_run, :running, project:, initiating_user: other_user)
      draft_revision

      expect {
        tool.call(project_id: project.id, agent_run_id: other_run.id, bundle_digest: bundle_digest, confirmed: true)
      }.to raise_error(Pundit::NotAuthorizedError, /Agent run not found or not accessible/)
    end

    it "denies another run initiated by the same user" do
      other_run = create(:agent_run, :running, project:, initiating_user: user)
      draft_revision

      expect {
        tool.call(project_id: project.id, agent_run_id: other_run.id, bundle_digest: bundle_digest, confirmed: true)
      }.to raise_error(Pundit::NotAuthorizedError, /Agent run not found or not accessible/)
    end

    it "reports the capability as unauthorized when the rollout flag is disabled" do
      FeatureFlags.disable!(:apple_verification_workers, project:)
      draft_revision

      expect {
        tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest, confirmed: true)
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "reports quota exhaustion as an argument error with a clear message" do
      revision = draft_revision
      create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "queued"
      )

      expect {
        tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest, confirmed: true)
      }.to raise_error(ArgumentError, /quota|active/i)
    end
  end

  describe Tools::CaptureAppleScreenshot do
    let(:tool) { described_class.new(user:, session:, agent_run:) }

    it "requests a declared capture" do
      draft_revision

      result = tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest,
        capture_id: "ios-app.initial-screen", confirmed: true)

      expect(result).to include("requested_capture" => "ios-app.initial-screen")
    end

    it "requires confirmation and rejects undeclared captures" do
      draft_revision

      expect {
        tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest,
          capture_id: "ios-app.initial-screen", confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)

      expect {
        tool.call(project_id: project.id, agent_run_id: agent_run.id, bundle_digest: bundle_digest,
          capture_id: "undeclared", confirmed: true)
      }.to raise_error(ArgumentError, /not declared/)
    end
  end

  describe Tools::StopAppleVerification do
    let(:tool) { described_class.new(user:, session:, agent_run:) }

    it "cancels the run's own active attempt" do
      revision = draft_revision
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "running"
      )

      result = tool.call(project_id: project.id, agent_run_id: agent_run.id, attempt_id: attempt.id, confirmed: true)

      expect(result["status"]).to eq("cancelled")
    end

    it "refuses another run's attempt" do
      revision = draft_revision
      other_run = create(:agent_run, :running, project:)
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run: other_run,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "running"
      )

      expect {
        tool.call(project_id: project.id, agent_run_id: agent_run.id, attempt_id: attempt.id, confirmed: true)
      }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe Tools::GetAppleVerification do
    let(:tool) { described_class.new(user:, session:, agent_run:) }

    it "returns structured state for the project and run" do
      draft_revision

      result = tool.call(project_id: project.id, agent_run_id: agent_run.id)

      expect(result).to include("mode" => "on_demand", "attempts" => [])
    end

    it "denies users outside the account" do
      outsider = create(:user)

      expect {
        described_class.new(user: outsider, session:).call(project_id: project.id, agent_run_id: agent_run.id)
      }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
