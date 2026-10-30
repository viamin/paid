# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Technical prerequisite validations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:source_run) { create(:agent_run, :completed, project:, issue:, base_commit_sha: "a" * 40) }
  let(:requirement) { create(:pre_commit_requirement, project:, account:, command: "bin/audit") }

  # @spec PARTIAL-CLOSEOUT-032
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

  # @spec PARTIAL-CLOSEOUT-032
  it "rejects a criterion-specific action after its assessment becomes stale" do
    sign_in user
    source_run

    expect {
      post validate_technical_prerequisite_project_agent_runs_path(project), params: {
        issue_id: issue.id, source_run_id: source_run.id, requirement_id: requirement.id,
        criterion: "Native analyzer runs on the pinned checkout"
      }
    }.not_to change(AgentRun, :count)

    expect(flash[:alert]).to include("no longer prepared")
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "records the criterion from a current prepared action on the validation run" do
    sign_in user
    criterion = "Native analyzer runs on the pinned checkout"
    source_run.update!(reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => criterion, "state" => "unmet", "validation_kind" => "native",
        "validation_requirement_id" => requirement.id } ]
    } })

    post validate_technical_prerequisite_project_agent_runs_path(project), params: {
      issue_id: issue.id, source_run_id: source_run.id, requirement_id: requirement.id, criterion: criterion
    }

    expect(response).to redirect_to(project_agent_run_path(project, AgentRun.where(synthetic: true).last))
    expect(AgentRun.where(synthetic: true).last.external_metadata.dig("technical_prerequisite_validation", "criterion"))
      .to eq(criterion)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "queues a validation run that never enters the agent execution queue" do
    sign_in user

    post validate_technical_prerequisite_project_agent_runs_path(project), params: {
      issue_id: issue.id, source_run_id: source_run.id, requirement_id: requirement.id
    }

    validation_run = AgentRun.where(synthetic: true).last
    expect(validation_run.goal).to eq("technical_prerequisite_validation")
    expect(AgentRun.unclaimed).not_to include(validation_run)
  end

  # @spec PARTIAL-CLOSEOUT-032
  it "opens the validation run page for progress and cancellation" do
    sign_in user

    post validate_technical_prerequisite_project_agent_runs_path(project), params: {
      issue_id: issue.id, source_run_id: source_run.id, requirement_id: requirement.id
    }

    validation_run = AgentRun.where(synthetic: true).last
    get project_agent_run_path(project, validation_run)

    expect(response).to have_http_status(:ok)
  end

  # @spec PARTIAL-CLOSEOUT-032
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

  # @spec PARTIAL-CLOSEOUT-032
  it "surfaces a refused validation as an actionable message instead of an error page" do
    sign_in user
    invalid_run = AgentRun.new(project:)
    invalid_run.errors.add(:issue, "is required")
    allow(TechnicalPrerequisites::StartValidation).to receive(:call)
      .and_raise(ActiveRecord::RecordInvalid.new(invalid_run))

    post validate_technical_prerequisite_project_agent_runs_path(project), params: {
      issue_id: issue.id, source_run_id: source_run.id, requirement_id: requirement.id
    }

    expect(response).to redirect_to(dashboard_path)
    expect(flash[:alert]).to include("is required")
  end
end
