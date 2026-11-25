# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Conflict-repair scope reassessment" do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:run) do
    create(:agent_run, :automatic, :failed, project:, focus: "merge_conflict",
      result_commit_sha: "a" * 40)
  end

  it "loads the selected run before authorizing and queues its reassessment" do # @spec AUTO-MERGE-011
    sign_in user

    expect {
      post reassess_conflict_repair_scope_project_agent_run_path(project, run)
    }.to have_enqueued_job(ReassessConflictRepairScopeJob).with(run.id, requested_by_id: user.id)

    expect(response).to redirect_to(project_agent_run_path(project, run))
  end

  it "rejects a manual producer before queueing reassessment" do # @spec AUTO-MERGE-011
    run.update!(trigger_type: "manual")
    sign_in user

    expect {
      post reassess_conflict_repair_scope_project_agent_run_path(project, run)
    }.not_to have_enqueued_job(ReassessConflictRepairScopeJob)

    expect(response).to redirect_to(project_agent_run_path(project, run))
    expect(flash[:alert]).to eq("This run is not an immutable failed automatic conflict-repair artifact.")
  end
end
