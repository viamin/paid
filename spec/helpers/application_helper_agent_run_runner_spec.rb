# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :db do
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

  describe "#agent_run_display_duration_seconds" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user) }

    it "returns the persisted duration when present" do
      run = create(:agent_run,
        project: project,
        status: "failed",
        created_at: 5.minutes.ago,
        started_at: 4.minutes.ago,
        completed_at: 2.minutes.ago,
        duration_seconds: 120)

      expect(helper.agent_run_display_duration_seconds(run)).to eq(120)
    end

    it "falls back to created-to-completed time for terminal runs that failed before start" do
      completed_at = Time.current
      run = create(:agent_run,
        project: project,
        status: "failed",
        created_at: completed_at - 36.seconds,
        started_at: nil,
        completed_at: completed_at,
        duration_seconds: nil)

      expect(helper.agent_run_display_duration_seconds(run)).to eq(36)
    end

    it "uses started-to-paused time for paused runs without a persisted duration" do
      paused_at = Time.current
      run = create(:agent_run,
        :paused,
        project: project,
        created_at: paused_at - 90.seconds,
        started_at: paused_at - 45.seconds,
        paused_at: paused_at,
        duration_seconds: nil)

      expect(helper.agent_run_display_duration_seconds(run)).to eq(45)
    end
  end
end
