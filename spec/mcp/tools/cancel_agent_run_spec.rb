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

    it "cancels a queued agent run" do
      run = create(:agent_run, :queued, project: project)

      result = tool.call(agent_run_id: run.id, confirmed: true)

      expect(result[:status]).to eq("cancelled")
    end

    it "cancels a paused agent run" do
      run = create(:agent_run, :paused, project: project)

      result = tool.call(agent_run_id: run.id, confirmed: true)

      expect(result[:status]).to eq("cancelled")
    end

    it "raises when not confirmed" do
      run = create(:agent_run, :running, project: project)

      expect {
        tool.call(agent_run_id: run.id, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "raises when run is not cancellable" do
      run = create(:agent_run, :completed, project: project)

      expect {
        tool.call(agent_run_id: run.id, confirmed: true)
      }.to raise_error(ArgumentError, /not cancellable/)
    end

    it "reuses the authorized run lookup during perform" do
      run = create(:agent_run, :running, project: project)
      scope = instance_double(ActiveRecord::Relation)

      allow(tool).to receive(:policy_scope).with(AgentRun).and_return(scope)
      expect(scope).to receive(:find).once.with(run.id).and_return(run)

      tool.call(agent_run_id: run.id, confirmed: true)
    end
  end
end
