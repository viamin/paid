# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunChannel, type: :channel do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let(:project) { create(:project, account: account) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  before do
    stub_connection current_user: user
  end

  describe "#subscribed" do
    it "streams for the agent run when authorized" do
      subscribe(id: agent_run.id)
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(agent_run)
    end

    it "rejects subscription for agent run from another account" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      other_run = create(:agent_run, :running, project: other_project)

      subscribe(id: other_run.id)
      expect(subscription).to be_rejected
    end

    it "rejects subscription for non-existent agent run" do
      subscribe(id: -1)
      expect(subscription).to be_rejected
    end
  end
end
