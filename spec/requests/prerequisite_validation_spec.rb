# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Prerequisite validation" do # @spec PREREQ-EVIDENCE-001 @spec PREREQ-EVIDENCE-007
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:notification) do
    Notifications::Publish.call(
      account: account,
      subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      severity: :error,
      blocking: true,
      title: "Execution evidence needed",
      description: "native-analyzer artifact: run a read-only analyzer from a fresh pinned run and attach result and cleanup artifacts."
    )
  end
  let(:healthy_hosts) do
    {
      "local" => { host: "local", healthy: true, checked_at: Time.current, failing_check: nil,
                   remediation_hint: nil, checks: [] },
      "remote" => { host: "remote", healthy: false, checked_at: Time.current, failing_check: "docker_ping",
                    remediation_hint: "Ensure Docker is running and reachable on remote.", checks: [] }
    }
  end

  before do
    sign_in user
    allow(Containers::HostReadiness).to receive(:call).and_return(healthy_hosts)
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:marketplace_tool_sidecars, anything).and_return(false)
    allow(PrerequisiteValidationJob).to receive(:perform_later)
  end

  def inbox_entry_id
    "action_required:#{notification.id}"
  end

  def expect_validation_panel
    expect(response.body).to include("id=\"prerequisite_validation_issue_#{issue.id}\"")
    expect(response.body).to include(execution_capabilities_project_agent_runs_path(project))
  end

  def complete_partial_validation!(validation)
    validation.complete!(status: "partial", result: {
      "checks" => { "native_analyzer" => { "status" => "succeeded", "exit_code" => 0 },
                    "tool_sidecar" => { "status" => "blocked", "authorized_action" => Prerequisites::CapabilityReport::FLAG_ENABLE_ACTION } },
      "checkout" => { "base_commit_sha" => "abc123def456" }, "requested_checks" => %w[native_analyzer tool_sidecar]
    })
  end

  describe "the originating Inbox item" do
    it "offers the capability-aware validation panel from the prerequisite item" do
      get inbox_entry_path(inbox_entry_id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)

      expect(response).to have_http_status(:ok)
      expect_validation_panel
    end
  end

  describe "GET /projects/:project_id/agent_runs/execution_capabilities" do
    it "inspects host capabilities and tool policy through the provisioner interface" do
      get execution_capabilities_project_agent_runs_path(project, issue_id: issue.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Execution-evidence validation")
      expect(response.body).to include("local", "ready")
      expect(response.body).to include("remote", "not ready: docker_ping")
      expect(response.body).to include("Ensure Docker is running and reachable on remote.")
      expect(response.body).to include("flag off")
      expect(response.body).to include("tenant_settings.features")
    end

    it "refuses an operator who may not run agents on the project" do
      outsider = create(:user)
      sign_out :user
      sign_in outsider

      get execution_capabilities_project_agent_runs_path(project, issue_id: issue.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the start → result → refresh journey" do
    it "starts a validation from the Inbox item and shows the finished evidence on the refreshed item" do
      expect {
        post validate_prerequisite_project_agent_runs_path(project),
          params: { issue_id: issue.id, return_to: inbox_path }
      }.to change(PrerequisiteValidation, :count).by(1)
      expect(response).to redirect_to(inbox_path)
      expect(PrerequisiteValidationJob).to have_received(:perform_later).once

      validation = PrerequisiteValidation.last
      expect(validation.issue).to eq(issue)
      expect(validation.requested_by).to eq(user)

      complete_partial_validation!(validation)

      get inbox_entry_path(inbox_entry_id, kind: Inbox::Queue::ACTION_REQUIRED_KIND)

      expect(response).to have_http_status(:ok)
      expect_validation_panel
    end

    it "shows the finished evidence, authorized actions, and the open-owner note in the panel" do
      PrerequisiteValidation.create!(
        account: account, project: project, issue: issue, requested_by: user,
        status: "partial", scope_digest: Prerequisites::CapabilityReport.scope_digest_for(project:),
        result: {
          "checks" => {
            "native_analyzer" => { "status" => "succeeded", "exit_code" => 0, "stdout" => "scc 3.7.0\nabc123\n" },
            "tool_sidecar" => { "status" => "blocked", "reason" => "Rollout flag off.", "authorized_action" => "Enable the flag via tenant settings." }
          },
          "checkout" => { "base_commit_sha" => "abc123def456" }
        },
        blockers: [ { "check" => "tool_sidecar", "reason" => "flag off", "authorized_action" => "Enable the flag via tenant settings." } ],
        started_at: 10.minutes.ago, completed_at: 5.minutes.ago
      )
      get execution_capabilities_project_agent_runs_path(project, issue_id: issue.id)

      expect(response.body).to include("Partial")
      expect(response.body).to include("Native analyzer", "succeeded", "exit 0")
      expect(response.body).to include("Tool sidecar", "blocked")
      expect(response.body).to include("Authorized action: Enable the flag via tenant settings.")
      expect(response.body).to include("abc123def456")
      expect(response.body).to include("keeps this prerequisite open", "Run a fresh validation")
    end

    it "marks terminal evidence stale when the policy scope changed" do
      PrerequisiteValidation.create!(
        account: account, project: project, issue: issue, requested_by: user,
        status: "succeeded", scope_digest: "an-old-digest",
        result: { "checks" => { "native_analyzer" => { "status" => "succeeded", "exit_code" => 0 } } },
        completed_at: 1.hour.ago
      )

      get execution_capabilities_project_agent_runs_path(project, issue_id: issue.id)

      expect(response.body).to include("stale")
      expect(response.body).to include("run a fresh validation")
    end

    it "offers cancellation while a validation is active instead of a second start" do
      validation = PrerequisiteValidation.create!(
        account: account, project: project, issue: issue, requested_by: user,
        status: "running", started_at: 1.minute.ago
      )

      get execution_capabilities_project_agent_runs_path(project, issue_id: issue.id)

      expect(response.body).to include("Cancel validation ##{validation.id}")
      expect(response.body).not_to include("Start execution-evidence validation")

      expect {
        post cancel_prerequisite_validation_project_agent_runs_path(project),
          params: { validation_id: validation.id, issue_id: issue.id, return_to: inbox_path }
      }.to change { validation.reload.status }.to("cancelled")
      expect(response).to redirect_to(inbox_path)
    end

    it "refuses a second validation while one is active" do
      PrerequisiteValidation.create!(account: account, project: project, issue: issue, requested_by: user, status: "running")

      expect {
        post validate_prerequisite_project_agent_runs_path(project), params: { issue_id: issue.id }
      }.not_to change(PrerequisiteValidation, :count)

      expect(flash[:alert]).to include("already")
    end
  end
end
