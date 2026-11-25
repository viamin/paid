# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::PrioritizeFirstImplementation do # @spec QUEUE-TIER-010
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true) }
  let(:run) { create(:agent_run, :queued, :automatic, project:, issue: create(:issue, project:), goal: "create_pr", auto_pick: true) }

  it "requires explicit confirmation before recording priority" do
    tool = described_class.new(user:, session:)
    expect { tool.call(project_id: project.id, agent_run_id: run.id, confirmed: false) }.to raise_error(ArgumentError, /Confirmation required/)
    expect(run.reload.operator_coding_priority_requested_at).to be_nil

    expect(tool.call(project_id: project.id, agent_run_id: run.id, confirmed: true)).to include(priority_requested: true)
  end
end
