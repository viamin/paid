# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ParseCrossRepoIssuePlanActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt,
      project: project, goal: "create_issue", custom_prompt: "Create cross-repo issue pair")
  end

  before do
    allow(agent_run).to receive(:broadcast_project_updates)
    allow(agent_run).to receive(:update_project_last_agent_run_at)
  end

  describe "#execute" do
    it "returns nil plan when agent output has no cross-repo markers" do
      agent_run.log!("stdout", "# Simple Issue\n\nJust a regular issue body.")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "parses a cross-repo issue plan from agent output" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- upstream: viamin/agent-harness -->
        <!-- upstream-title: Add streaming support to harness API -->

        <!-- upstream-body-start -->
        The agent-harness gem should expose a streaming interface for LLM responses.

        ## Acceptance Criteria
        - [ ] Add `stream:` option to `AgentHarness::Client#execute`
        <!-- upstream-body-end -->

        # Adopt streaming in Paid

        Once agent-harness supports streaming, Paid should adopt it in RunAgentActivity.
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      plan = result[:plan]
      expect(plan).not_to be_nil
      expect(plan[:target_repo]).to eq("viamin/agent-harness")
      expect(plan[:upstream_title]).to eq("Add streaming support to harness API")
      expect(plan[:upstream_body]).to include("streaming interface")
      expect(plan[:downstream_body]).to include("Adopt streaming in Paid")
    end

    it "returns nil when upstream title is missing" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- upstream: viamin/agent-harness -->
        <!-- upstream-body-start -->
        Some body
        <!-- upstream-body-end -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "returns nil when upstream body is missing" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- upstream: viamin/agent-harness -->
        <!-- upstream-title: Some title -->
      OUTPUT

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "returns nil when no agent output exists" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:plan]).to be_nil
    end

    it "logs when a cross-repo plan is detected" do
      agent_run.log!("stdout", <<~OUTPUT)
        <!-- upstream: viamin/agent-harness -->
        <!-- upstream-title: Fix bug -->
        <!-- upstream-body-start -->
        Fix the bug
        <!-- upstream-body-end -->
        Downstream work here.
      OUTPUT

      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.find_by(log_type: "system")
      expect(log.content).to include("cross-repo issue plan")
      expect(log.content).to include("viamin/agent-harness")
    end
  end
end
