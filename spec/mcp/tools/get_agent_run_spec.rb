# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetAgentRun do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe "#call" do
    it "returns agent run attributes" do
      run = create(:agent_run, :completed, :with_metrics, project: create(:project, account: account))

      result = tool.call(agent_run_id: run.id)

      expect(result).to include(
        id: run.id,
        project_id: run.project_id,
        issue_id: run.issue_id,
        status: "completed",
        goal: run.goal,
        agent_type: run.agent_type,
        pull_request_url: run.pull_request_url,
        iterations: run.iterations,
        tokens_input: run.tokens_input,
        tokens_output: run.tokens_output,
        cost_cents: run.cost_cents
      )
    end

    it "raises for runs outside the user's account" do
      other_run = create(:agent_run)

      expect { tool.call(agent_run_id: other_run.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "reuses the authorized run lookup during perform" do
      run = create(:agent_run, project: create(:project, account: account))
      scope = instance_double(ActiveRecord::Relation)

      allow(tool).to receive(:policy_scope).with(AgentRun).and_return(scope)
      expect(scope).to receive(:find).once.with(run.id).and_return(run)

      tool.call(agent_run_id: run.id)
    end
  end
end
