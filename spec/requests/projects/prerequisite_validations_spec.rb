# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects prerequisite validations" do # @spec PREREQ-EXEC-005 # @spec PREREQ-EXEC-006 # @spec PREREQ-EXEC-013 # @spec PREREQ-EXEC-014 # @spec PREREQ-EXEC-015 # @spec PREREQ-EXEC-016 # @spec PREREQ-EXEC-017
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, active: true,
      owner: "acme", repo: "alpha", owner_reviewer_login: "viamin")
  end
  # A stalled closeout: open issue with terminal merged-PR evidence, plus a
  # linked open prerequisite owner issue (#4604-like).
  let(:parent_issue) { create(:issue, project: project, github_number: 500, paid_state: "in_progress") }
  let(:prerequisite) { create(:issue, project: project, github_number: 4604, github_state: "open") }

  before do
    sign_in user
    FeatureFlags.flipper.features.each(&:remove)
    create(:issue_dependency, issue: parent_issue, depends_on_issue: prerequisite)
    create(:issue, :pull_request, project: project, github_number: 502, github_state: "closed",
      pr_review_phase: "merged", parent_issue: parent_issue, created_at: 2.days.ago)
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
  end

  def open_partial_closeout_entry
    get inbox_entry_path("partial_closeout:#{parent_issue.id}",
      project_id: project.id, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
    expect(response).to have_http_status(:ok)
  end

  describe "the originating Inbox item" do
    # @spec PREREQ-EXEC-015
    it "renders the capability report and the bounded validation action for the linked prerequisite" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")

      open_partial_closeout_entry

      expect(response.body).to include("Execution-evidence validation")
      expect(response.body).to include("available")
      expect(response.body).to include("#4604")
      expect(response.body).to include(project_prerequisite_validations_path(project))
    end

    it "renders the exact authorized setup action when no backend is placement-ready" do
      open_partial_closeout_entry

      expect(response.body).to include("unavailable")
      expect(response.body).to include("Add or enable a Docker host")
    end
  end

  describe "starting a validation from the Inbox action" do
    # @spec PREREQ-EXEC-006
    it "creates the bounded attempt, records terminal evidence, and refreshes the Inbox state" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
      performed = []
      allow(PrerequisiteExecutions::ValidationJob).to receive(:perform_later) { |id| performed << id }

      expect {
        post project_prerequisite_validations_path(project),
          params: { issue_id: prerequisite.id, native_command: "bin/lint", branch: "main", return_to: inbox_path }
      }.to change(PrerequisiteExecutionValidation, :count).by(1)

      validation = PrerequisiteExecutionValidation.last
      expect(performed).to eq([ validation.id ])
      expect(response).to redirect_to(project_prerequisite_validation_path(project, validation))
      expect(validation.agent_run.goal).to eq("prerequisite_validation")

      # The executed job records terminal evidence; the refreshed Inbox
      # entry surfaces it.
      validation.update!(status: "succeeded", steps: [
        { "key" => "native_analyzer", "status" => "succeeded", "exit_code" => 0, "stdout" => "clean" }
      ], evidence: { "identity" => { "checkout" => { "branch" => "main", "commit" => "abc123" } } },
        finished_at: Time.current)

      open_partial_closeout_entry
      expect(response.body).to include("succeeded")
      expect(response.body).to include(project_prerequisite_validation_path(project, validation))
    end

    it "records unavailable with the authorized action instead of provisioning" do
      expect {
        post project_prerequisite_validations_path(project),
          params: { issue_id: prerequisite.id, native_command: "bin/lint", branch: "main", return_to: inbox_path }
      }.to change(PrerequisiteExecutionValidation, :count).by(1)

      validation = PrerequisiteExecutionValidation.last
      expect(validation.status).to eq("unavailable")
      expect(validation.agent_run).to be_nil
      expect(response).to redirect_to(project_prerequisite_validation_path(project, validation))
    end

    it "refuses a blank analyzer command" do
      post project_prerequisite_validations_path(project),
        params: { issue_id: prerequisite.id, native_command: "", branch: "main" }

      expect(response).to redirect_to(inbox_path)
      expect(flash[:alert]).to include("analyzer command")
    end
  end

  describe "progress and evidence via the API surface" do
    # @spec PREREQ-EXEC-016
    it "exposes the capability report as JSON" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")

      get capabilities_project_prerequisite_validations_path(project), headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body
      expect(payload["environment_available"]).to be(true)
      expect(payload["compatible_hosts"]).to eq([ "remote-1" ])
    end

    it "exposes status, steps, and evidence as JSON" do
      validation = create(:prerequisite_execution_validation, :succeeded, project: project, issue: prerequisite)

      get project_prerequisite_validation_path(project, validation), headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body
      expect(payload["status"]).to eq("succeeded")
      expect(payload["steps"]).to be_present
      expect(payload["evidence"]["identity"]["checkout"]["commit"]).to be_present
    end

    it "renders the evidence page for an authorized operator" do
      validation = create(:prerequisite_execution_validation, :succeeded, project: project, issue: prerequisite)

      get project_prerequisite_validation_path(project, validation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Execution-evidence validation")
      expect(response.body).to include("native_analyzer".humanize)
    end
  end

  describe "cancellation and retry" do
    # @spec PREREQ-EXEC-013
    it "cancels an active attempt from the supported surface" do
      validation = create(:prerequisite_execution_validation, :running, project: project, issue: prerequisite)
      allow(PrerequisiteExecutionValidation).to receive(:find).and_call_original

      post cancel_project_prerequisite_validation_path(project, validation),
        params: { return_to: project_prerequisite_validation_path(project, validation) }

      expect(validation.reload).to be_cancelled
      expect(validation.agent_run.reload.status).to eq("cancelled")
    end

    # @spec PREREQ-EXEC-014
    it "revalidates on retry with a changed scope and marks prior evidence stale" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
      validation = create(:prerequisite_execution_validation, :succeeded, project: project, issue: prerequisite)
      validation.update!(contract: validation.contract.merge("native_command" => "bin/lint -a"))

      expect {
        post retry_project_prerequisite_validation_path(project, validation),
          params: { return_to: inbox_path }
      }.to change(PrerequisiteExecutionValidation, :count).by(1)

      expect(validation.reload).to be_stale
      expect(PrerequisiteExecutionValidation.last).not_to be_stale
    end

    it "returns existing evidence when retrying a succeeded attempt of the same scope" do
      create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
      validation = create(:prerequisite_execution_validation, :succeeded, project: project, issue: prerequisite,
        scope_digest: same_scope_digest)

      expect {
        post retry_project_prerequisite_validation_path(project, validation),
          params: { return_to: inbox_path }
      }.not_to change(PrerequisiteExecutionValidation, :count)

      expect(response).to redirect_to(project_prerequisite_validation_path(project, validation))
    end
  end

  # The digest Start computes for this factory contract (branch "main",
  # command "bin/lint", no tool, flag off).
  def same_scope_digest
    Digest::SHA256.hexdigest([ "main", "bin/lint", nil, nil, false ].join("\n"))
  end

  # @spec PREREQ-EXEC-017
  it "never mutates the prerequisite issue while collecting evidence" do
    create(:docker_host, account: account, identifier: "remote-1", backend_type: "remote")
    original_state = prerequisite.github_state
    allow(PrerequisiteExecutions::ValidationJob).to receive(:perform_later)

    post project_prerequisite_validations_path(project),
      params: { issue_id: prerequisite.id, native_command: "bin/lint", branch: "main" }

    prerequisite.reload
    expect(prerequisite.github_state).to eq(original_state)
    expect(prerequisite.paid_state).to eq("new")
  end
end
