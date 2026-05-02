# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListAgentRuns do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe "#call" do
    let(:project) { create(:project, account: account) }

    it "returns runs for the user's account" do
      run = create(:agent_run, project: project)
      create(:agent_run) # other account

      result = tool.call

      expect(result.size).to eq(1)
      expect(result.first[:id]).to eq(run.id)
    end

    it "filters by project_id" do
      other_project = create(:project, account: account)
      create(:agent_run, project: project)
      create(:agent_run, project: other_project)

      result = tool.call(project_id: project.id)

      expect(result.size).to eq(1)
    end

    it "filters by status" do
      create(:agent_run, :running, project: project)
      create(:agent_run, :completed, project: project)

      result = tool.call(status: "running")

      expect(result.size).to eq(1)
      expect(result.first[:status]).to eq("running")
    end
  end
end
