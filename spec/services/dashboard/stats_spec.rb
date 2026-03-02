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

      it "returns zero issue completion counts" do
        completion = stats[:issue_completion]
        expect(completion[:total_issues]).to eq(0)
        expect(completion[:completed_count]).to eq(0)
        expect(completion[:failed_count]).to eq(0)
        expect(completion[:in_progress_count]).to eq(0)
        expect(completion[:completion_rate]).to eq(0.0)
      end

      it "returns zero issue completion aggregates" do
        completion = stats[:issue_completion]
        expect(completion[:runs_per_issue]).to eq(avg: 0.0, min: 0, max: 0, median: 0.0)
        expect(completion[:time_to_merge]).to eq(avg: 0, p50: 0, p90: 0)
        expect(completion[:agent_minutes]).to eq(avg: 0, p50: 0, p90: 0)
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

    context "with completed issues" do
      let(:first_issue) { create(:issue, :completed, project: project, updated_at: 1.day.ago) }
      let(:second_issue) { create(:issue, :completed, project: project, updated_at: 2.days.ago) }
      let(:failed_issue) { create(:issue, :failed, project: project) }
      let(:in_progress_issue) { create(:issue, :in_progress, project: project) }

      before do
        # First issue: 2 agent runs, total 900s agent time
        create(:agent_run, :completed, project: project, issue: first_issue,
          duration_seconds: 600, created_at: 3.days.ago)
        create(:agent_run, :completed, project: project, issue: first_issue,
          duration_seconds: 300, created_at: 2.days.ago)

        # Second issue: 1 agent run, 400s agent time
        create(:agent_run, :completed, project: project, issue: second_issue,
          duration_seconds: 400, created_at: 5.days.ago)

        # Failed issue: has a run but should not be counted in completion aggregates
        create(:agent_run, :failed, project: project, issue: failed_issue,
          duration_seconds: 100, created_at: 1.day.ago)

        # In-progress issue
        create(:agent_run, :running, project: project, issue: in_progress_issue,
          created_at: 1.hour.ago)
      end

      it "counts issues by state" do
        completion = stats[:issue_completion]
        expect(completion[:total_issues]).to eq(4)
        expect(completion[:completed_count]).to eq(2)
        expect(completion[:failed_count]).to eq(1)
        expect(completion[:in_progress_count]).to eq(1)
      end

      it "calculates completion rate" do
        # 2 completed / 4 total = 50.0%
        expect(stats[:issue_completion][:completion_rate]).to eq(50.0)
      end

      it "calculates runs per completed issue" do
        runs = stats[:issue_completion][:runs_per_issue]
        # Issue 1: 2 runs, Issue 2: 1 run -> avg 1.5, median 1.5, min 1, max 2
        expect(runs[:avg]).to eq(1.5)
        expect(runs[:min]).to eq(1)
        expect(runs[:max]).to eq(2)
        expect(runs[:median]).to eq(1.5)
      end

      it "calculates agent execution time per issue" do
        agent = stats[:issue_completion][:agent_minutes]
        # Issue 1: 900s, Issue 2: 400s -> avg 650s
        expect(agent[:avg]).to eq(650)
        expect(agent[:p50]).to be > 0
        expect(agent[:p90]).to be > 0
      end

      it "calculates time-to-merge stats" do
        ttm = stats[:issue_completion][:time_to_merge]
        expect(ttm[:avg]).to be > 0
        expect(ttm[:p50]).to be > 0
        expect(ttm[:p90]).to be > 0
      end

      it "excludes pull request issues from counts" do
        create(:issue, :pull_request, :completed, project: project)
        completion = stats[:issue_completion]
        expect(completion[:total_issues]).to eq(4)
        expect(completion[:completed_count]).to eq(2)
      end
    end

    context "with issues from another account" do
      let(:other_account) { create(:account) }
      let(:other_project) { create(:project, account: other_account) }

      before do
        other_issue = create(:issue, :completed, project: other_project)
        create(:agent_run, :completed, project: other_project, issue: other_issue)

        my_issue = create(:issue, :completed, project: project)
        create(:agent_run, :completed, project: project, issue: my_issue)
      end

      it "only includes issues from the specified account" do
        expect(stats[:issue_completion][:total_issues]).to eq(1)
        expect(stats[:issue_completion][:completed_count]).to eq(1)
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
