# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Technical prerequisite validations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:source_run) { create(:agent_run, :completed, project:, issue:, base_commit_sha: "a" * 40) }
  let(:requirement) { create(:pre_commit_requirement, project:, account:, command: "bin/audit") }

  # @spec PARTIAL-CLOSEOUT-030
  it "queues an authorized validation from the Inbox action" do
    sign_in user

    expect {
      post validate_technical_prerequisite_project_agent_runs_path(project), params: {
        issue_id: issue.id, source_run_id: source_run.id, requirement_id: requirement.id
      }
    }.to change { AgentRun.where(synthetic: true).count }.by(1)

    validation_run = AgentRun.where(synthetic: true).last
    expect(response).to redirect_to(project_agent_run_path(project, validation_run))
    expect(TechnicalPrerequisiteValidationJob).to have_been_enqueued.with(validation_run.id)
  end

  # @spec PARTIAL-CLOSEOUT-030
  it "refuses a recipe outside the effective project configuration" do
    sign_in user
    other_project = create(:project, account:, created_by: user)
    other_requirement = create(:pre_commit_requirement, project: other_project, account:)
    source_run

    expect {
      post validate_technical_prerequisite_project_agent_runs_path(project), params: {
        issue_id: issue.id, source_run_id: source_run.id, requirement_id: other_requirement.id
      }
    }.not_to change(AgentRun, :count)

    expect(response).to redirect_to(dashboard_path)
  end
end
