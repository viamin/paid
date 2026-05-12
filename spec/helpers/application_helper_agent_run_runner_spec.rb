# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#agent_run_runner_display" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user) }

    it "uses the preloaded runner association without extra runner queries" do
      runner = create(:runner, user: user, runner_key: "codex")
      run = create(:agent_run, project: project, runner: runner, final_runner: nil)
      preloaded_run = AgentRun.includes(:runner).find(run.id)

      queries = capture_queries do
        expect(helper.agent_run_runner_display(preloaded_run)).to eq(runner.display_name)
      end

      runner_queries = queries.grep(/FROM "runners"/)
      expect(runner_queries).to be_empty
    end

    it "resolves an unloaded routed fallback run to the final runner record" do
      initial_runner = create(:runner, user: user, runner_key: "codex")
      fallback_runner = create(:runner, user: user, runner_key: "cursor")
      run = create(:agent_run, project: project, runner: initial_runner, final_runner: fallback_runner.routing_key)

      expect(helper.agent_run_runner_display(run)).to eq(fallback_runner.display_name)
    end

    it "prefers the final runner identifier when it differs from the originally requested runner" do
      initial_runner = create(:runner, user: user, runner_key: "codex")
      run = create(:agent_run, project: project, runner: initial_runner, final_runner: "cursor")

      expect(helper.agent_run_runner_display(run)).to eq(Runner.display_name_for("cursor"))
    end

    it "renders a placeholder for unsupported runner identifiers" do
      run = create(:agent_run, project: project, runner: nil, final_runner: "api", agent_type: "api")

      expect(helper.agent_run_runner_display(run)).to eq("Api")
    end
  end
end
