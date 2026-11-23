# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-011
RSpec.describe ReassessConflictRepairScopeJob do
  let(:project) { create(:project) }
  let(:requester) { create(:user, :member, account: project.account) }
  let(:run) { create(:agent_run, project:) }

  it "reauthorizes the requester at execution time" do
    requester.membership_for(project.account).update!(role: :viewer)

    expect {
      described_class.perform_now(run.id, requested_by_id: requester.id)
    }.to raise_error(Pundit::NotAuthorizedError, /no longer authorized/)
  end

  it "rejects a retry without a requesting actor" do
    expect {
      described_class.perform_now(run.id, requested_by_id: nil)
    }.to raise_error(Pundit::NotAuthorizedError, /no longer authorized/)
  end

  it "does not reassess a manual producer" do
    run.update!(trigger_type: "manual")
    expect(ConflictRepairs::ReassessScope).not_to receive(:call)

    described_class.perform_now(run.id, requested_by_id: requester.id)
  end
end
