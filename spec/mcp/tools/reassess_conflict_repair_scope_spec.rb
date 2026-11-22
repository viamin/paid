# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-011
RSpec.describe Tools::ReassessConflictRepairScope do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:project) { create(:project, account:) }
  let(:run) { create(:agent_run, :automatic, :failed, project:, focus: "merge_conflict", result_commit_sha: "a" * 40) }

  it "offers the same confirmed artifact-only action to MCP" do
    expect { described_class.new(user:, session:).call(agent_run_id: run.id, confirmed: true) }
      .to have_enqueued_job(ReassessConflictRepairScopeJob).with(run.id, requested_by_id: user.id)
    expect(run.reload.status).to eq("failed")
    expect(project.agent_runs.count).to eq(1)
  end
end
