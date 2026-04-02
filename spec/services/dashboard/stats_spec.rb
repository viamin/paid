# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::Stats do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  def create_timed_completed_run(project:, created_at:)
    create(:agent_run, :completed, project: project,
      created_at: created_at, started_at: created_at + 1.minute,
      completed_at: created_at + 2.minutes, duration_seconds: 60)
  end

  def create_setup_phase(agent_run, duration_seconds:)
    create(:agent_run_phase, agent_run: agent_run, phase_group: "setup",
      duration_seconds: duration_seconds, started_at: agent_run.started_at,
      finished_at: agent_run.started_at + duration_seconds.seconds)
  end

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

      it "returns empty agent type, provider, and project breakdowns" do
        expect(stats[:runs_by_agent_type]).to be_empty
        expect(stats[:runs_by_provider]).to be_empty
        expect(stats[:runs_by_project]).to be_empty
      end

      it "returns zero provider fallback stats" do
        fs = stats[:provider_fallback_stats]
        expect(fs[:total_runs]).to eq(0)
        expect(fs[:fallback_count]).to eq(0)
        expect(fs[:fallback_rate]).to eq(0.0)
        expect(fs[:by_requested_provider]).to be_empty
        expect(fs[:by_effective_provider]).to be_empty
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

      it "calculates phase breakdown percentiles" do
        completed_runs = AgentRun.where(project: project, status: "completed").order(:duration_seconds).to_a

        create(:agent_run_phase, agent_run: completed_runs[0], phase_group: "setup", duration_seconds: 10, started_at: 2.days.ago, finished_at: 2.days.ago + 10.seconds)
        create(:agent_run_phase, agent_run: completed_runs[0], phase_group: "agent", duration_seconds: 80, started_at: 2.days.ago + 20.seconds, finished_at: 2.days.ago + 100.seconds)

        create(:agent_run_phase, agent_run: completed_runs[1], phase_group: "setup", duration_seconds: 20, started_at: 5.days.ago, finished_at: 5.days.ago + 20.seconds)
        create(:agent_run_phase, agent_run: completed_runs[1], phase_group: "agent", duration_seconds: 160, started_at: 5.days.ago + 30.seconds, finished_at: 5.days.ago + 190.seconds)

        create(:agent_run_phase, agent_run: completed_runs[2], phase_group: "setup", duration_seconds: 40, started_at: 20.days.ago, finished_at: 20.days.ago + 40.seconds)
        create(:agent_run_phase, agent_run: completed_runs[2], phase_group: "agent", duration_seconds: 500, started_at: 20.days.ago + 60.seconds, finished_at: 20.days.ago + 560.seconds)

        expect(stats[:phase_breakdown]["setup"][:avg_seconds]).to eq(23)
        expect(stats[:phase_breakdown]["agent"][:p50_seconds]).to eq(160)
        expect(stats[:phase_breakdown]["queue"][:sample_size]).to eq(3)
      end

      it "skips completed runs without phase rows" do
        completed_run = AgentRun.where(project: project, status: "completed").first
        create_setup_phase(completed_run, duration_seconds: 20)

        expect(stats[:phase_breakdown]["setup"][:sample_size]).to eq(1)
        expect(stats[:phase_breakdown]["setup"][:avg_seconds]).to eq(20)
        expect(stats[:phase_breakdown]["queue"][:sample_size]).to eq(1)
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

    context "with performance_by_outcome" do
      before do
        create(:agent_run, :completed, project: project, cost_cents: 100,
          tokens_input: 1000, tokens_output: 500, duration_seconds: 60)
        create(:agent_run, :completed, project: project, cost_cents: 200,
          tokens_input: 2000, tokens_output: 1000, duration_seconds: 120)
        create(:agent_run, project: project, status: "failed", cost_cents: 50,
          tokens_input: 500, tokens_output: 250, duration_seconds: 30)
        create(:agent_run, project: project, status: "timeout", cost_cents: 300,
          tokens_input: 3000, tokens_output: 1500, duration_seconds: 600)
      end

      it "separates completed from other outcomes" do
        completed = stats[:performance_by_outcome]["completed"]
        other = stats[:performance_by_outcome]["other"]

        expect(completed[:run_count]).to eq(2)
        expect(completed[:total_cost_cents]).to eq(300)
        expect(completed[:avg_cost_cents]).to eq(150)

        expect(other[:run_count]).to eq(2)
        expect(other[:total_cost_cents]).to eq(350)
        expect(other[:avg_cost_cents]).to eq(175)
      end
    end

    context "with performance_by_goal" do
      before do
        create(:agent_run, :completed, project: project, goal: "create_pr",
          cost_cents: 200, tokens_input: 2000, tokens_output: 1000, duration_seconds: 120)
        create(:agent_run, :completed, project: project, goal: "create_issue",
          cost_cents: 50, tokens_input: 500, tokens_output: 250, duration_seconds: 30)
        create(:agent_run, project: project, goal: "create_pr", status: "failed",
          cost_cents: 100, tokens_input: 1000, tokens_output: 500, duration_seconds: 60)
      end

      it "breaks down by goal type" do
        pr = stats[:performance_by_goal]["create_pr"]
        issue = stats[:performance_by_goal]["create_issue"]

        expect(pr[:run_count]).to eq(2)
        expect(pr[:total_cost_cents]).to eq(300)
        expect(issue[:run_count]).to eq(1)
        expect(issue[:total_cost_cents]).to eq(50)
      end

      it "includes outcome sub-breakdown per goal" do
        pr = stats[:performance_by_goal]["create_pr"]
        expect(pr[:by_outcome]["completed"][:run_count]).to eq(1)
        expect(pr[:by_outcome]["completed"][:avg_cost_cents]).to eq(200)
        expect(pr[:by_outcome]["other"][:run_count]).to eq(1)
        expect(pr[:by_outcome]["other"][:avg_cost_cents]).to eq(100)
      end

      it "returns zeros for goal types with no runs" do
        review = stats[:performance_by_goal]["review"]
        expect(review[:run_count]).to eq(0)
        expect(review[:total_cost_cents]).to eq(0)
      end
    end

    context "with time_range filter" do
      before do
        create(:agent_run, :completed, project: project, created_at: 2.days.ago, cost_cents: 100)
        create(:agent_run, :completed, project: project, created_at: 10.days.ago, cost_cents: 200)
        create(:agent_run, :completed, project: project, created_at: 40.days.ago, cost_cents: 300)
      end

      it "returns all runs for cumulative" do
        result = described_class.call(account: account, time_range: "cumulative")
        expect(result[:run_volume][:total]).to eq(3)
      end

      it "filters to past 7 days" do
        result = described_class.call(account: account, time_range: "7d")
        expect(result[:run_volume][:total]).to eq(1)
      end

      it "filters to past 30 days" do
        result = described_class.call(account: account, time_range: "30d")
        expect(result[:run_volume][:total]).to eq(2)
      end

      it "filters to past 24 hours" do
        result = described_class.call(account: account, time_range: "24h")
        expect(result[:run_volume][:total]).to eq(0)
      end
    end

    context "with status and goal filters on performance" do
      before do
        create(:agent_run, :completed, project: project, goal: "create_pr",
          cost_cents: 100, tokens_input: 1000, tokens_output: 500, duration_seconds: 60)
        create(:agent_run, project: project, goal: "create_pr", status: "failed",
          cost_cents: 50, tokens_input: 500, tokens_output: 250, duration_seconds: 30)
        create(:agent_run, :completed, :review_goal, project: project,
          cost_cents: 75, tokens_input: 800, tokens_output: 400, duration_seconds: 45)
      end

      it "filters performance by status" do
        result = described_class.call(account: account, status_filter: "completed")
        completed = result[:performance_by_outcome]["completed"]
        expect(completed[:run_count]).to eq(2)
        expect(result[:performance_by_outcome]["other"][:run_count]).to eq(0)
      end

      it "filters performance by goal" do
        result = described_class.call(account: account, goal_filter: "create_pr")
        pr = result[:performance_by_goal]["create_pr"]
        expect(pr[:run_count]).to eq(2)
        # review goal shows 0 because the data is filtered to create_pr only
        review = result[:performance_by_goal]["review"]
        expect(review[:run_count]).to eq(0)
      end

      it "combines status and goal filters" do
        result = described_class.call(account: account, status_filter: "completed", goal_filter: "create_pr")
        completed = result[:performance_by_outcome]["completed"]
        expect(completed[:run_count]).to eq(1)
        expect(completed[:avg_cost_cents]).to eq(100)
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

    context "with many completed runs for phase breakdown" do
      it "limits phase breakdown to recent completed runs" do
        travel_to Time.zone.parse("2026-03-20 12:00:00 UTC") do
          stub_const("Dashboard::Stats::PHASE_BREAKDOWN_RUN_LIMIT", 2)

          recent_runs = [
            create_timed_completed_run(project: project, created_at: 5.days.ago),
            create_timed_completed_run(project: project, created_at: 4.days.ago),
            create_timed_completed_run(project: project, created_at: 3.days.ago)
          ]

          create_setup_phase(recent_runs[0], duration_seconds: 5)
          create_setup_phase(recent_runs[1], duration_seconds: 10)
          create_setup_phase(recent_runs[2], duration_seconds: 20)

          old_run = create_timed_completed_run(project: project, created_at: 45.days.ago)
          create_setup_phase(old_run, duration_seconds: 999)

          expect(stats[:phase_breakdown]["setup"][:sample_size]).to eq(2)
          expect(stats[:phase_breakdown]["setup"][:avg_seconds]).to eq(15)
        end
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

    context "with provider fallbacks" do
      before do
        # Run requested claude_code, completed by claude_code (no fallback)
        create(:agent_run, :completed, project: project, agent_type: "claude_code")
        # Run requested claude_code, fell back to codex
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          final_provider: "codex", provider_switches: 1)
        # Run requested claude_code, fell back to cursor
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          final_provider: "cursor", provider_switches: 1)
        # Run requested cursor, completed by cursor (no fallback)
        create(:agent_run, :completed, :cursor, project: project)
      end

      it "groups runs_by_provider by effective provider" do
        providers = stats[:runs_by_provider]
        provider_hash = providers.to_h
        # claude: 1 (no fallback, claude_code normalized), codex: 1 (fallback), cursor: 2 (1 direct + 1 fallback)
        expect(provider_hash["claude"]).to eq(1)
        expect(provider_hash["codex"]).to eq(1)
        expect(provider_hash["cursor"]).to eq(2)
      end

      it "still groups runs_by_agent_type by requested provider" do
        types = stats[:runs_by_agent_type].to_h
        expect(types["claude_code"]).to eq(3)
        expect(types["cursor"]).to eq(1)
      end

      it "calculates fallback rate" do
        fs = stats[:provider_fallback_stats]
        expect(fs[:total_runs]).to eq(4)
        expect(fs[:fallback_count]).to eq(2)
        expect(fs[:fallback_rate]).to eq(50.0)
      end

      it "breaks down fallbacks by requested provider" do
        by_requested = stats[:provider_fallback_stats][:by_requested_provider].to_h
        expect(by_requested["claude_code"]).to eq(2)
      end

      it "breaks down fallbacks by effective provider" do
        by_effective = stats[:provider_fallback_stats][:by_effective_provider].to_h
        expect(by_effective["codex"]).to eq(1)
        expect(by_effective["cursor"]).to eq(1)
      end
    end

    context "with provider fallback via skipped primary (no provider_switches)" do
      before do
        # Primary provider was skipped as unavailable; fallback used directly.
        # final_provider differs from agent_type but provider_switches remains 0.
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          final_provider: "cursor", provider_switches: 0)
        # Normal run with no fallback
        create(:agent_run, :completed, project: project, agent_type: "claude_code")
      end

      it "counts the skipped-primary run as a fallback" do
        fs = stats[:provider_fallback_stats]
        expect(fs[:total_runs]).to eq(2)
        expect(fs[:fallback_count]).to eq(1)
        expect(fs[:fallback_rate]).to eq(50.0)
      end

      it "attributes the skipped-primary run to the effective provider" do
        providers = stats[:runs_by_provider].to_h
        expect(providers["cursor"]).to eq(1)
        expect(providers["claude"]).to eq(1)
      end
    end

    context "with claude_code run completed by claude provider (no fallback)" do
      before do
        # final_provider is the normalized provider key "claude" for agent_type "claude_code".
        # This should NOT be counted as a fallback.
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          final_provider: "claude", provider_switches: 0)
      end

      it "does not count normalized provider match as a fallback" do
        fs = stats[:provider_fallback_stats]
        expect(fs[:fallback_count]).to eq(0)
        expect(fs[:fallback_rate]).to eq(0.0)
      end

      it "groups under the claude provider" do
        providers = stats[:runs_by_provider].to_h
        expect(providers["claude"]).to eq(1)
        expect(providers).not_to have_key("claude_code")
      end
    end

    context "with legacy final_provider matching agent_type (no fallback)" do
      before do
        # final_provider contains the legacy agent-type identifier "claude_code"
        # rather than the normalized provider key "claude". Both should normalize
        # to "claude", so this must NOT be counted as a fallback.
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          final_provider: "claude_code", provider_switches: 0)
      end

      it "does not count legacy final_provider as a fallback" do
        fs = stats[:provider_fallback_stats]
        expect(fs[:fallback_count]).to eq(0)
        expect(fs[:fallback_rate]).to eq(0.0)
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

    describe "cost_by_project" do
      context "with no projects having costs" do
        it "returns an empty array" do
          expect(stats[:cost_by_project]).to be_empty
        end
      end

      context "with projects having costs" do
        let(:expensive_project) { create(:project, account: account, name: "Expensive Project", total_cost_cents: 5000) }
        let(:cheap_project) { create(:project, account: account, name: "Cheap Project", total_cost_cents: 100) }

        before do
          project.update!(total_cost_cents: 1000)
          expensive_project
          cheap_project
        end

        it "only includes projects with non-zero costs" do
          names = stats[:cost_by_project].map(&:first)
          expect(names).to include(project.name, "Expensive Project", "Cheap Project")
        end

        it "orders by cost descending" do
          result = stats[:cost_by_project]
          expect(result.first).to eq([ "Expensive Project", 5000 ])
          expect(result.last).to eq([ "Cheap Project", 100 ])
        end

        it "excludes zero-cost projects" do
          create(:project, account: account, name: "Free Project", total_cost_cents: 0)
          names = stats[:cost_by_project].map(&:first)
          expect(names).not_to include("Free Project")
        end
      end

      context "with projects from another account" do
        let(:other_account) { create(:account) }

        before do
          create(:project, account: other_account, name: "Other Project", total_cost_cents: 9999)
          project.update!(total_cost_cents: 500)
        end

        it "only includes projects from the specified account" do
          names = stats[:cost_by_project].map(&:first)
          expect(names).to include(project.name)
          expect(names).not_to include("Other Project")
        end
      end

      context "with more than 10 projects" do
        before do
          12.times do |i|
            create(:project, account: account, name: "Project #{i}", total_cost_cents: (i + 1) * 100)
          end
        end

        it "limits results to 10" do
          expect(stats[:cost_by_project].length).to eq(10)
        end
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
