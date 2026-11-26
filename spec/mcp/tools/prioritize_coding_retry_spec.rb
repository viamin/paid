# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::PrioritizeCodingRetry do # @spec QUEUE-TIER-008
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:agent_run) do
    create(:agent_run, :queued, :automatic, :existing_pr, project:, goal: "create_pr")
  end

  it "uses the authorized service without converting the automatic retry to manual" do
    result = tool.call(project_id: project.id, agent_run_id: agent_run.id, confirmed: true)

    expect(result).to include(agent_run_id: agent_run.id, priority_requested: true)
    expect(agent_run.reload).to have_attributes(trigger_type: "automatic")
    expect(agent_run.operator_coding_priority_requested_at).to be_present
  end

  it "requires confirmation and does not let an untrusted request set priority" do
    expect {
      tool.call(project_id: project.id, agent_run_id: agent_run.id, confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)

    expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
  end

  it "refuses a retained queued retry after confirmation" do # @spec QUEUE-TIER-008
    agent_run.update!(container_id: "retained-container")

    expect {
      tool.call(project_id: project.id, agent_run_id: agent_run.id, confirmed: true)
    }.to raise_error(ArgumentError, /no longer eligible/)

    expect(agent_run.reload).to have_attributes(container_id: "retained-container", operator_coding_priority_requested_at: nil)
  end
end
