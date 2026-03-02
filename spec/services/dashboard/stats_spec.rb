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

      it "returns zero issue completion stats" do
        ic = stats[:issue_completion]
        expect(ic[:merged_count]).to eq(0)
        expect(ic[:runs_per_issue]).to eq(avg: 0.0, min: 0, max: 0, median: 0.0)
        expect(ic[:time_to_merge]).to eq(avg_seconds: 0, p50_seconds: 0, p90_seconds: 0)
        expect(ic[:agent_run_seconds]).to eq(avg_seconds: 0, p50_seconds: 0, p90_seconds: 0)
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

    context "with merged PRs" do
      let(:merged_issue) do
        create(:issue, :pull_request, :closed, project: project,
          pr_review_phase: "merged",
          github_created_at: 5.days.ago,
          github_updated_at: 1.day.ago)
      end

      before do
        create(:agent_run, :completed, project: project, issue: merged_issue,
          duration_seconds: 300, created_at: 4.days.ago, started_at: 4.days.ago)
        create(:agent_run, :completed, project: project, issue: merged_issue,
          duration_seconds: 200, created_at: 3.days.ago, started_at: 3.days.ago)
        create(:agent_run, :completed, project: project, issue: merged_issue,
          duration_seconds: 100, created_at: 2.days.ago, started_at: 2.days.ago)
      end

      it "counts merged PRs" do
        expect(stats[:issue_completion][:merged_count]).to eq(1)
      end

      it "calculates runs per issue" do
        rpi = stats[:issue_completion][:runs_per_issue]
        expect(rpi[:avg]).to eq(3.0)
        expect(rpi[:min]).to eq(3)
        expect(rpi[:max]).to eq(3)
        expect(rpi[:median]).to eq(3.0)
      end

      it "calculates time to merge as wall clock seconds" do
        ttm = stats[:issue_completion][:time_to_merge]
        # Wall clock: github_updated_at (1.day.ago) - first run started_at (4.days.ago) = 3 days
        expected_seconds = (merged_issue.github_updated_at - 4.days.ago).to_i
        expect(ttm[:avg_seconds]).to be_within(5).of(expected_seconds)
        expect(ttm[:p50_seconds]).to be_within(5).of(expected_seconds)
      end

      it "calculates agent run seconds" do
        arm = stats[:issue_completion][:agent_run_seconds]
        # Total: 300 + 200 + 100 = 600 seconds
        expect(arm[:avg_seconds]).to eq(600)
        expect(arm[:p50_seconds]).to eq(600)
      end
    end

    context "with multiple merged PRs" do
      let(:issue_a) do
        create(:issue, :pull_request, :closed, project: project,
          pr_review_phase: "merged",
          github_created_at: 10.days.ago,
          github_updated_at: 8.days.ago)
      end
      let(:issue_b) do
        create(:issue, :pull_request, :closed, project: project,
          pr_review_phase: "merged",
          github_created_at: 5.days.ago,
          github_updated_at: 1.day.ago)
      end

      before do
        # Issue A: 1 run, 120s duration, started 9 days ago
        create(:agent_run, :completed, project: project, issue: issue_a,
          duration_seconds: 120, created_at: 9.days.ago, started_at: 9.days.ago)
        # Issue B: 3 runs, total 900s duration, first started 4 days ago
        create(:agent_run, :completed, project: project, issue: issue_b,
          duration_seconds: 300, created_at: 4.days.ago, started_at: 4.days.ago)
        create(:agent_run, :completed, project: project, issue: issue_b,
          duration_seconds: 300, created_at: 3.days.ago, started_at: 3.days.ago)
        create(:agent_run, :completed, project: project, issue: issue_b,
          duration_seconds: 300, created_at: 2.days.ago, started_at: 2.days.ago)
      end

      it "counts all merged PRs" do
        expect(stats[:issue_completion][:merged_count]).to eq(2)
      end

      it "calculates runs per issue across multiple issues" do
        rpi = stats[:issue_completion][:runs_per_issue]
        # Issue A: 1 run, Issue B: 3 runs -> avg 2.0
        expect(rpi[:avg]).to eq(2.0)
        expect(rpi[:min]).to eq(1)
        expect(rpi[:max]).to eq(3)
      end

      it "calculates agent run seconds across issues" do
        arm = stats[:issue_completion][:agent_run_seconds]
        # Issue A: 120s, Issue B: 900s -> avg 510
        expect(arm[:avg_seconds]).to eq(510)
      end
    end

    context "with merged PRs from another account" do
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      before do
        other_issue = create(:issue, :pull_request, :closed, project: other_project,
          pr_review_phase: "merged",
          github_created_at: 5.days.ago,
          github_updated_at: 1.day.ago)
        create(:agent_run, :completed, project: other_project, issue: other_issue,
          duration_seconds: 300)
      end

      it "excludes merged PRs from other accounts" do
        expect(stats[:issue_completion][:merged_count]).to eq(0)
      end
    end

    context "with non-merged PRs" do
      before do
        open_pr = create(:issue, :pull_request, project: project,
          pr_review_phase: "draft",
          github_created_at: 5.days.ago,
          github_updated_at: 1.day.ago)
        create(:agent_run, :completed, project: project, issue: open_pr,
          duration_seconds: 300)
      end

      it "does not count non-merged PRs" do
        expect(stats[:issue_completion][:merged_count]).to eq(0)
      end
    end
  end
end
