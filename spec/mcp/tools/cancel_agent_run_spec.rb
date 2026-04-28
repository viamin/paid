# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::CancelAgentRun do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe ".write_operation?" do
    it "returns true" do
      expect(described_class.write_operation?).to be(true)
    end
  end

  describe "#call" do
    let(:project) { create(:project, account: account) }

    it "cancels an active agent run" do
      run = create(:agent_run, :running, project: project)

      result = tool.call(agent_run_id: run.id, confirmed: true)

      expect(result[:status]).to eq("cancelled")
    end

    it "raises when not confirmed" do
      run = create(:agent_run, :running, project: project)

      expect {
        tool.call(agent_run_id: run.id, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "raises when run is not active" do
      run = create(:agent_run, :completed, project: project)

      expect {
        tool.call(agent_run_id: run.id, confirmed: true)
      }.to raise_error(ArgumentError, /not active/)
    end
  end
end
