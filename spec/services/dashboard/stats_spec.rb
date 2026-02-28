# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::Stats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    subject(:stats) { described_class.call(account: account) }

    context "with no agent runs" do
      it "returns zero counts" do
        expect(stats[:run_volume][:total]).to eq(0)
        expect(stats[:run_volume][:last_7_days]).to eq(0)
        expect(stats[:run_volume][:last_30_days]).to eq(0)
        expect(stats[:run_volume][:active]).to eq(0)
      end

      it "returns zero failure rate" do
        expect(stats[:run_volume][:failure_rate]).to eq(0.0)
      end

      it "returns nil-safe duration percentiles" do
        expect(stats[:duration_percentiles][:p50]).to eq(0)
        expect(stats[:duration_percentiles][:p75]).to eq(0)
        expect(stats[:duration_percentiles][:p90]).to eq(0)
        expect(stats[:duration_percentiles][:avg]).to eq(0)
      end

      it "returns zero cost and tokens" do
        expect(stats[:cost_and_tokens][:total_cost_cents]).to eq(0)
        expect(stats[:cost_and_tokens][:total_tokens]).to eq(0)
      end

      it "returns empty agent type and project breakdowns" do
        expect(stats[:runs_by_agent_type]).to be_empty
        expect(stats[:runs_by_project]).to be_empty
      end
    end

    context "with agent runs" do
      before do
        create(:agent_run, :completed, project: project, duration_seconds: 100,
          tokens_input: 1000, tokens_output: 500, cost_cents: 50, iterations: 3,
          created_at: 2.days.ago)
        create(:agent_run, :completed, project: project, duration_seconds: 200,
          tokens_input: 2000, tokens_output: 1000, cost_cents: 100, iterations: 5,
          created_at: 5.days.ago)
        create(:agent_run, :completed, project: project, duration_seconds: 600,
          tokens_input: 5000, tokens_output: 2500, cost_cents: 250, iterations: 8,
          created_at: 20.days.ago)
        create(:agent_run, :failed, project: project, duration_seconds: 50,
          created_at: 3.days.ago)
        create(:agent_run, :running, project: project,
          created_at: 1.hour.ago)
      end

      it "counts total runs" do
        expect(stats[:run_volume][:total]).to eq(5)
      end

      it "counts runs in time windows" do
        expect(stats[:run_volume][:last_7_days]).to eq(4)
        expect(stats[:run_volume][:last_30_days]).to eq(5)
      end

      it "counts active runs" do
        expect(stats[:run_volume][:active]).to eq(1)
      end

      it "groups runs by status" do
        expect(stats[:run_volume][:by_status]["completed"]).to eq(3)
        expect(stats[:run_volume][:by_status]["failed"]).to eq(1)
        expect(stats[:run_volume][:by_status]["running"]).to eq(1)
      end

      it "calculates failure rate" do
        # 1 failed / (3 completed + 1 failed) = 25.0%
        expect(stats[:run_volume][:failure_rate]).to eq(25.0)
      end

      it "calculates duration percentiles for completed runs" do
        expect(stats[:duration_percentiles][:p50]).to eq(200)
        expect(stats[:duration_percentiles][:avg]).to eq(300)
        expect(stats[:duration_percentiles][:p90]).to be > 0
      end

      it "calculates cost totals" do
        expect(stats[:cost_and_tokens][:total_cost_cents]).to eq(400)
      end

      it "calculates token totals" do
        # (1000+500) + (2000+1000) + (5000+2500) = 12000
        expect(stats[:cost_and_tokens][:total_tokens]).to eq(12_000)
      end

      it "calculates per-run averages for completed runs" do
        # 400 cents / 3 completed = 133
        expect(stats[:cost_and_tokens][:avg_cost_per_run_cents]).to eq(133)
        # 12000 tokens / 3 completed = 4000
        expect(stats[:cost_and_tokens][:avg_tokens_per_run]).to eq(4000)
      end

      it "calculates average iterations per completed run" do
        # (3 + 5 + 8) / 3 = 5.3
        expect(stats[:cost_and_tokens][:avg_iterations_per_run]).to eq(5.3)
      end

      it "groups runs by agent type" do
        expect(stats[:runs_by_agent_type]).to include([ "claude_code", 5 ])
      end

      it "groups runs by project" do
        expect(stats[:runs_by_project]).to include([ project.name, 5 ])
      end
    end

    context "with runs from another account" do
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      before do
        create(:agent_run, :completed, project: other_project)
        create(:agent_run, :completed, project: project)
      end

      it "only includes runs from the specified account" do
        expect(stats[:run_volume][:total]).to eq(1)
      end
    end

    context "with multiple agent types" do
      before do
        create(:agent_run, :completed, project: project)
        create(:agent_run, :completed, :cursor, project: project)
        create(:agent_run, :completed, :cursor, project: project)
      end

      it "sorts agent types by count descending" do
        types = stats[:runs_by_agent_type]
        expect(types.first).to eq([ "cursor", 2 ])
        expect(types.last).to eq([ "claude_code", 1 ])
      end
    end

    context "with multiple projects" do
      let(:project2) { create(:project, account: account, name: "Active Project") }

      before do
        create_list(:agent_run, 3, :completed, project: project2)
        create(:agent_run, :completed, project: project)
      end

      it "limits to top 5 projects sorted by run count" do
        projects = stats[:runs_by_project]
        expect(projects.first).to eq([ "Active Project", 3 ])
        expect(projects.length).to be <= 5
      end
    end
  end
end
