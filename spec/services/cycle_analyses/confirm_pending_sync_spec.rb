# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::ConfirmPendingSync do
  # @spec AUTO-PICK-QUEUE-019
  it "requeues confirmation after synchronization parses the repaired declaration source" do
    user = create(:user)
    source_project = create(:project, account: user.account, created_by: user)
    run_project = create(:project, account: user.account, created_by: user)
    run = create(:agent_run, :completed, project: run_project, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => {
        "status" => "pending_sync", "details" => { "project_id" => source_project.id, "issue_number" => 42 }
      } } })

    expect { described_class.call(project: source_project, issue_numbers: [ 42 ]) }
      .to have_enqueued_job(CycleAnalysisJob).with(run.id)

    expect(run.reload).to have_attributes(status: "queued", completed_at: nil)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "requeues local confirmation for a cancelled run with a persisted repair" do
    user = create(:user)
    source_project = create(:project, account: user.account, created_by: user)
    run_project = create(:project, account: user.account, created_by: user)
    run = create(:agent_run, :cancelled, project: run_project, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => {
        "status" => "pending_sync", "details" => { "project_id" => source_project.id, "issue_number" => 42 }
      } } })

    expect { described_class.call(project: source_project, issue_numbers: [ 42 ]) }
      .to have_enqueued_job(CycleAnalysisJob).with(run.id)

    expect(run.reload).to have_attributes(status: "queued", completed_at: nil)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not requeue confirmation until synchronization parses its declaration source" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    run = create(:agent_run, :completed, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      verification_result: { CycleAnalyses::RESULT_KEY => { "repair" => {
        "status" => "pending_sync", "details" => { "project_id" => project.id, "issue_number" => 42 }
      } } })

    expect { described_class.call(project:, issue_numbers: [ 99 ]) }
      .not_to have_enqueued_job(CycleAnalysisJob)

    expect(run.reload.status).to eq("completed")
  end
end
