# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::ScanPaidPrsActivity do
  fixture "activities/scan_paid_prs/base"

  let(:activity) { described_class.new }
  let(:fixture_repository) { instance_variable_get(:@_fixture_kit_repository) }
  let(:project) { fixture_repository.project }
  let(:octokit_client) { instance_double(Octokit::Client) }
  let(:github_client) { instance_double(GithubClient, client: octokit_client) }

  # Scanner tests that exercise the ":no_review → emit review_bot_review_pending"
  # path need the project to have a requestable review bot configured. Without
  # it, the scanner correctly returns no triggers (there is no bot to request).
  def enable_copilot_review!(proj = project)
    proj.update!(review_settings: {
      "enabled" => true,
      "methods" => { "copilot" => { "enabled" => true } }
    })
  end

  def enable_codex_review!(proj = project)
    proj.update!(review_settings: {
      "enabled" => true,
      "methods" => { "codex" => { "enabled" => true } }
    })
  end

  def enable_copilot_and_codex_review!(proj = project)
    proj.update!(review_settings: {
      "enabled" => true,
      "methods" => {
        "copilot" => { "enabled" => true },
        "codex" => { "enabled" => true }
      }
    })
  end

  def enable_paid_agent_review!(proj = project, max_review_rounds: 3, max_review_goal_retries: nil)
    termination = { "max_review_rounds" => max_review_rounds }
    termination["max_review_goal_retries"] = max_review_goal_retries if max_review_goal_retries

    proj.update!(review_settings: {
      "enabled" => true,
      "methods" => {
        "paid_agent" => {
          "enabled" => true,
          "termination" => termination
        }
      }
    })
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(rate_limit_remaining!: 100, check_run_log: "")
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  describe "#evaluate_auto_merge" do
    let(:selected_strategy) { instance_double(Automation::Strategies::AutoMerge) }
    let(:signals) do
      Automation::Strategies::AutoMerge::Signals.build(
        issue_id: 123,
        pr_number: 42,
        bot_authored: true,
        dependabot_eligible: true,
        checks_green: true,
        mergeable: true
      )
    end
    let(:merge_result) do
      Automation::Result.new(decisions: [ Automation::Decision.merge(issue_id: 123, pr_number: 42) ])
    end

    it "selects the auto-merge strategy through Automation::Strategies::Select" do
      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_merge, project: project)
        .and_return(selected_strategy)
      allow(selected_strategy).to receive(:evaluate).and_return(merge_result)

      result = activity.send(:evaluate_auto_merge, project, signals)

      expect(result).to be(true)
      expect(Automation::Strategies::Select).to have_received(:call)
        .with(strategy_type: :auto_merge, project: project)
      expect(selected_strategy).to have_received(:evaluate).with(
        have_attributes(project: project)
      )
    end
  end

  describe "#dependencies_resolved?" do
    let(:pr_issue) do
      create(:issue, :pull_request,
        project: project,
        github_number: 42,
        body: body)
    end
    let(:body) { "Depends on #41" }

    before do
      allow(github_client).to receive(:issue_comments)
        .with(project.full_name, 42)
        .and_return(issue_comments)
    end

    context "when a same-repo dependency PR is not merged" do
      let(:issue_comments) { [] }

      before do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 41)
          .and_return(OpenStruct.new(number: 41, merged: false, merged_at: nil))
      end

      it "returns false" do
        expect(activity.send(:dependencies_resolved?, github_client, project, pr_issue)).to be(false)
      end
    end

    context "when a dependency was removed in comments" do
      let(:issue_comments) { [ OpenStruct.new(body: "No longer depends on #41") ] }

      it "returns true without checking the removed PR" do
        expect(github_client).not_to receive(:pull_request).with(project.full_name, 41)

        expect(activity.send(:dependencies_resolved?, github_client, project, pr_issue)).to be(true)
      end
    end

    context "when a dependency references another repo" do
      let(:body) { "Depends on other/repo#41" }
      let(:issue_comments) { [] }

      it "returns false conservatively" do
        expect(activity.send(:dependencies_resolved?, github_client, project, pr_issue)).to be(false)
      end
    end
  end

  describe "#execute" do
    context "when project is missing" do
      it "returns empty result with project_missing flag" do
        result = activity.execute(project_id: -1)

        expect(result[:prs_to_trigger]).to eq([])
        expect(result[:automation_results]).to eq([])
        expect(result[:project_missing]).to be true
      end
    end

    context "when auto_scan_prs is disabled" do
      before { project.update!(auto_scan_prs: false) }

      it "returns empty result" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(result[:automation_results]).to eq([])
      end
    end

    context "when explicit PR decisions are enabled" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed")
      end

      before do
        FeatureFlags.enable!(:explicit_pr_automation_decisions, project:)
        pr_issue
      end

      it "returns automation results instead of legacy trigger payloads" do
        stub_github_for_pr(checks: [ { name: "rspec", conclusion: "failure" } ])

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(result[:automation_results]).to contain_exactly(
          {
            decisions: [
              { type: "queue_create_pr_run", issue_id: pr_issue.id, source_pull_request_number: 42, focus: "general" },
              { type: "record_pr_followup", issue_id: pr_issue.id, labels_to_remove: [], expected_followup_count: 0 }
            ]
          }
        )
      end
    end

    context "when explicit PR decisions are disabled" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed")
      end

      before do
        FeatureFlags.disable!(:explicit_pr_automation_decisions, project:)
        pr_issue
      end

      it "returns only legacy trigger payloads" do
        stub_github_for_pr(checks: [ { name: "rspec", conclusion: "failure" } ])

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).not_to be_empty
        expect(result[:automation_results]).to eq([])
      end

      it "does not build lifecycle signals for legacy trigger payloads" do
        allow(activity).to receive(:scan_pr).and_return({ pr_number: 42, triggers: [ { type: "ci_failure" } ] })
        allow(activity).to receive(:build_lifecycle_signals).and_call_original

        activity.execute(project_id: project.id)

        expect(activity).not_to have_received(:build_lifecycle_signals)
      end

      it "logs legacy trigger counts when rate limiting interrupts the scan" do
        create(:issue, :pull_request,
          project: project,
          github_number: 43,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed")
        scan_count = 0
        allow(activity).to receive(:scan_pr) do
          scan_count += 1
          raise Temporalio::Error::ApplicationError.new("rate limited", type: "RateLimit") if scan_count == 2

          { pr_number: 42, triggers: [ { type: "ci_failure" } ] }
        end
        allow(Rails.logger).to receive(:warn)

        activity.execute(project_id: project.id)

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "pr_scanner.rate_budget_exhausted_mid_scan",
            project_id: project.id,
            prs_collected: 1
          )
        )
      end
    end

    context "when rate limit is low" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 99,
          labels: [ project.generated_label_name, project.automation_label_name ],
          paid_state: "completed")
      end

      before { pr_issue }

      it "returns partial results when rate budget is exhausted mid-scan" do
        allow(github_client).to receive(:rate_limit_remaining!).and_return(5)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "returns empty when no PRs exist even with low rate limit" do
        pr_issue.update!(github_state: "closed")
        allow(github_client).to receive(:rate_limit_remaining!).and_return(5)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "skips PRs with active runs without checking rate budget" do
        create(:agent_run, project: project, source_pull_request_number: 99, status: "running")
        allow(github_client).to receive(:rate_limit_remaining!).and_return(5)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(github_client).not_to have_received(:rate_limit_remaining!)
      end

      it "escalates draft PRs at max review rounds without checking rate budget" do
        project.update!(max_draft_review_rounds: 3)
        pr_issue.update!(pr_review_phase: "draft", draft_review_count: 3)
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 99)
          .and_return(OpenStruct.new(draft: true, number: 99, head: OpenStruct.new(sha: "abc123", repo: OpenStruct.new(fork: false)), mergeable: true, user: OpenStruct.new(login: "someone-else")))
        allow(github_client).to receive(:rate_limit_remaining!).and_return(5)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(github_client).not_to have_received(:rate_limit_remaining!)
      end
    end

    context "when project uses a custom automation_label_name" do
      let(:custom_project) do
        create(:project,
          auto_scan_prs: true,
          max_pr_followup_runs: 3,
          pr_action_labels: [],
          auto_fix_merge_conflicts: false,
          generated_label_name: "my-generated-label",
          automation_label_name: "my-custom-automation")
      end
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: custom_project,
          github_number: 55,
          labels: [ "my-generated-label", "my-custom-automation" ],
          paid_state: "completed")
      end

      before do
        pr_issue
        allow(github_client).to receive_messages(
          pull_request: OpenStruct.new(draft: true, head: OpenStruct.new(sha: "abc123"), mergeable: true, user: OpenStruct.new(login: "viamin")),
          check_runs_for_ref: [ { name: "rspec", conclusion: "failure" } ],
          review_threads: [],
          pull_request_reviews: [],
          issue_comments: [],
          recent_issue_comments: []
        )
      end

      it "finds PRs with the custom automation label" do
        result = activity.execute(project_id: custom_project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:pr_number]).to eq(55)
      end
    end

    context "when a PR only has the generated label" do
      before do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated" ],
          paid_state: "completed")
      end

      it "does not treat it as auto-continue eligible" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when there are no automation-labeled PRs" do
      it "returns empty result" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when a PR has auto_continue_paused set to true" do
      before do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed",
          auto_continue_paused: true)
      end

      it "does not include the paused PR in scan results" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when a paid-generated PR has CI failures" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed")
      end

      before do
        pr_issue # ensure record exists
        stub_github_for_pr(
          checks: [
            { name: "rspec", conclusion: "failure" },
            { name: "rubocop", conclusion: "success" }
          ]
        )
      end

      it "detects CI failures and returns PR for follow-up" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:pr_number]).to eq(42)
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
        expect(trigger[:triggers].first[:details]).to eq([ "rspec" ])
      end

      it "does not increment pr_followup_count (workflow handles mutations)" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_followup_count).to eq(0)
      end

      it "returns empty labels_to_remove when no actionable labels" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].first[:labels_to_remove]).to eq([])
      end

      it "defaults focus to general when focused agent runs are disabled" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].first[:focus]).to eq("general")
      end
    end

    context "when focused agent runs are enabled" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation", "needs-docs" ],
          paid_state: "completed")
      end

      before do
        FeatureFlags.enable!(:focused_agent_runs, project:)
        project.update!(pr_action_labels: [ "needs-docs" ], auto_fix_merge_conflicts: true)
        pr_issue
        allow(github_client).to receive_messages(
          pull_request: OpenStruct.new(
            draft: false,
            number: 42,
            head: OpenStruct.new(sha: "abc123", repo: OpenStruct.new(fork: false)),
            mergeable: false,
            user: OpenStruct.new(login: "someone-else")
          ),
          check_runs_for_ref: [ { name: "rspec", conclusion: "failure" } ],
          review_threads: [],
          pull_request_reviews: [],
          issue_comments: [],
          recent_issue_comments: []
        )
      end

      it "resolves focus from the highest-priority trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].first[:focus]).to eq("merge_conflict")
      end

      it "resolves review feedback focus for review triggers" do
        expect(activity.send(:resolve_focus, [ { type: "review_threads" } ])).to eq("review_feedback")
      end

      it "resolves general focus when no trigger maps to a specific focus" do
        expect(activity.send(:resolve_focus, [ { type: "owner_approved" } ])).to eq("general")
      end
    end

    context "when attributing focus resolution for a ci_fix run" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
      end
      let!(:focused_run) do
        create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "ci_fix",
          iterations: 2)
      end
      let!(:metric) do
        create(:quality_metric, :automated,
          agent_run: focused_run,
          scores: { "iterations" => 0.9 },
          composite_score: 0.9)
      end

      it "records focus_resolved and recalculates the composite when CI is green" do
        stub_github_for_pr(checks: [ { name: "ci", conclusion: "success" } ])

        activity.execute(project_id: project.id)

        expect(metric.reload.scores).to include(
          "focus_resolved" => 1.0,
          "ci_passed" => 1.0
        )
        expect(metric.composite_score).to eq(0.9833)
      end

      it "defers recording while CI is still pending" do
        stub_github_for_pr(checks: [ { name: "ci", conclusion: nil } ])

        activity.execute(project_id: project.id)

        expect(metric.reload.scores).not_to include("focus_resolved", "ci_passed")
        expect(metric.composite_score).to eq(0.9)
      end

      it "defers recording when PR data cannot be fetched" do
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "GitHub API unavailable")

        activity.execute(project_id: project.id)

        expect(metric.reload.scores).not_to include("focus_resolved", "ci_passed")
        expect(metric.composite_score).to eq(0.9)
      end

      it "does not overwrite an existing focus_resolved score on later scans" do
        metric.update!(
          scores: metric.scores.merge("focus_resolved" => 1.0, "ci_passed" => 1.0),
          composite_score: 0.9833
        )
        stub_github_for_pr(checks: [ { name: "ci", conclusion: "failure" } ])

        activity.execute(project_id: project.id)

        expect(metric.reload.scores).to include(
          "focus_resolved" => 1.0,
          "ci_passed" => 1.0
        )
        expect(metric.composite_score).to eq(0.9833)
      end
    end

    context "when attributing focus resolution for a review_feedback run" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
      end
      let!(:focused_run) do
        create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "review_feedback")
      end
      let!(:metric) do
        create(:quality_metric, :automated,
          agent_run: focused_run,
          scores: { "iterations" => 1.0, "lint_clean" => 1.0 },
          composite_score: 1.0)
      end

      it "records 0.0 when unresolved threads remain" do
        stub_github_for_pr(
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Please fix this", path: "app/model.rb", line: 10, author: "viamin" } ]
            }
          ]
        )

        activity.execute(project_id: project.id)

        expect(metric.reload.scores["focus_resolved"]).to eq(0.0)
      end

      it "does not backfill an older focused run once a newer focused run exists" do
        older_metric = metric
        newer_run = create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "ci_fix",
          completed_at: 5.minutes.ago)
        create(:quality_metric, :automated,
          agent_run: newer_run,
          scores: { "iterations" => 1.0 },
          composite_score: 1.0)

        stub_github_for_pr(checks: [ { name: "ci", conclusion: "success" } ])

        activity.execute(project_id: project.id)

        expect(older_metric.reload.scores).not_to include("focus_resolved")
      end
    end

    context "when attributing focus resolution for a merge_conflict run" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
      end
      let!(:focused_run) do
        create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "merge_conflict")
      end
      let!(:metric) do
        create(:quality_metric, :automated,
          agent_run: focused_run,
          scores: { "iterations" => 1.0 },
          composite_score: 1.0)
      end

      it "records 1.0 when the PR is mergeable again" do
        stub_github_for_pr(mergeable: true)

        activity.execute(project_id: project.id)

        expect(metric.reload.scores["focus_resolved"]).to eq(1.0)
      end
    end

    context "when attributing focus resolution for a conversation run" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
      end
      let!(:focused_run) do
        create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "conversation",
          completed_at: 30.minutes.ago)
      end
      let!(:metric) do
        create(:quality_metric, :automated,
          agent_run: focused_run,
          scores: { "iterations" => 1.0, "lint_clean" => 1.0 },
          composite_score: 1.0)
      end

      it "records 1.0 when no actionable comments remain" do
        old_comment = OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "Already addressed in the last run",
          created_at: 2.hours.ago
        )
        stub_github_for_pr(issue_comments: [ old_comment ])

        activity.execute(project_id: project.id)

        expect(metric.reload.scores["focus_resolved"]).to eq(1.0)
      end
    end

    context "when an issue_implementation run exists" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
      end
      let!(:focused_run) do
        create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "issue_implementation")
      end
      let!(:metric) do
        create(:quality_metric, :automated,
          agent_run: focused_run,
          scores: { "iterations" => 1.0, "lint_clean" => 1.0 },
          composite_score: 1.0)
      end

      it "records focus_resolved once follow-up signals are cleared" do
        stub_github_for_pr

        activity.execute(project_id: project.id)

        expect(metric.reload.scores).to include(
          "focus_resolved" => 1.0,
          "ci_passed" => 1.0
        )
        expect(metric.composite_score).to eq(1.0)
      end
    end

    context "when attributing focus resolution for a label_action run" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
      end
      let!(:focused_run) do
        create(:agent_run, :completed,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          focus: "label_action")
      end
      let!(:metric) do
        create(:quality_metric, :automated,
          agent_run: focused_run,
          scores: { "iterations" => 1.0, "lint_clean" => 1.0 },
          composite_score: 1.0)
      end

      before do
        project.update!(pr_action_labels: [ "needs-docs" ])
      end

      it "records 1.0 when actionable labels are gone" do
        stub_github_for_pr

        activity.execute(project_id: project.id)

        expect(metric.reload.scores["focus_resolved"]).to eq(1.0)
      end
    end

    context "when checks are still pending" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          checks: [
            { name: "rspec", conclusion: nil },
            { name: "rubocop", conclusion: "success" }
          ]
        )
      end

      it "does not trigger when all completed checks pass" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when some checks failed but others are still pending" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          checks: [
            { name: "rspec", conclusion: "failure" },
            { name: "deploy", conclusion: nil },
            { name: "rubocop", conclusion: "success" }
          ]
        )
      end

      it "detects CI failures on completed checks without waiting for pending ones" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
        expect(trigger[:triggers].first[:details]).to eq([ "rspec" ])
      end
    end

    context "when all checks are still pending" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          checks: [
            { name: "rspec", conclusion: nil },
            { name: "rubocop", conclusion: nil }
          ]
        )
      end

      it "does not trigger when no checks have completed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when CI failure is transient and retryable" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed")
      end

      before do
        pr_issue
        allow(github_client).to receive_messages(check_run_log: "", rerun_workflow_run_failed_jobs: true)
      end

      it "retries transient CI failures instead of triggering agent run" do
        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "Error: getaddrinfo ENOTFOUND registry.npmjs.org",
              details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(pr_issue.reload.ci_retry_requested_at).to be_present
      end

      it "calls rerun_workflow_run_failed_jobs with the correct run_id" do
        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "connect ETIMEDOUT 104.16.23.35:443",
              details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
          ]
        )

        expect(github_client).to receive(:rerun_workflow_run_failed_jobs)
          .with(project.full_name, "12345")

        activity.execute(project_id: project.id)
      end

      it "does not retry when ci_retry_requested_at is within cooldown" do
        pr_issue.update_column(:ci_retry_requested_at, 10.minutes.ago)

        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "Error: getaddrinfo ENOTFOUND registry.npmjs.org",
              details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ci_failure")
      end

      it "retries again after cooldown expires" do
        pr_issue.update_column(:ci_retry_requested_at, 45.minutes.ago)

        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "Error: getaddrinfo ENOTFOUND registry.npmjs.org",
              details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "does not retry non-transient CI failures" do
        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "SyntaxError: unexpected end of input",
              details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ci_failure")
        expect(pr_issue.reload.ci_retry_requested_at).to be_nil
      end

      it "falls through to normal trigger when rerun fails" do
        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "Error: getaddrinfo ENOTFOUND registry.npmjs.org",
              details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
          ]
        )

        allow(github_client).to receive(:rerun_workflow_run_failed_jobs)
          .and_raise(GithubClient::Error.new("Forbidden"))

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ci_failure")
      end

      it "falls through when check has no details_url for run_id extraction" do
        stub_github_for_pr(
          checks: [
            { id: 1, name: "rspec", conclusion: "failure",
              output_text: "connect ETIMEDOUT 104.16.23.35:443",
              details_url: nil }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
      end
    end

    context "when there are unresolved review threads from trusted users" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "viamin" } ]
            }
          ]
        )
      end

      it "detects unresolved review threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("review_threads")
      end
    end

    context "when there are new conversation comments from trusted users" do
      let(:comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "Please fix the error handling in the parser module",
          created_at: 30.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(issue_comments: [ comment ])
      end

      it "detects new conversation comments" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("conversation_comments")
      end
    end

    context "when the recent comment page starts with an older-than-cutoff comment" do
      # Regression: GithubClient#recent_issue_comments returns comments in
      # ascending order within the page, so a newer-than-cutoff comment can
      # appear AFTER an older-than-cutoff comment in the same response. The
      # scanner must scan the full page, not short-circuit on the first
      # older entry.
      let(:old_comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "This comment is older than the last agent run — should be ignored",
          created_at: 2.hours.ago
        )
      end
      let(:new_comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "Please also address the logging around the parser fallback path",
          created_at: 20.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        # Ascending order within the page — the older comment comes first.
        stub_github_for_pr(issue_comments: [ old_comment, new_comment ])
      end

      it "still detects the newer comment that follows an older-than-cutoff entry" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("conversation_comments")
      end
    end

    [ 100, 50 ].each do |page_size|
      context "when multi-page recent comments (#{page_size} per page) are all newer than cutoff" do
        # When every comment on the last page is newer than the cutoff,
        # earlier post-cutoff comments may exist on previous pages. The
        # scanner should fall back to full pagination to avoid missing them.
        let(:recent_page) do
          Array.new(page_size) do |i|
            OpenStruct.new(
              user: OpenStruct.new(login: "bot-user"),
              body: "Automated update ##{i}",
              created_at: (50 - (i / 2)).minutes.ago
            )
          end
        end
        let(:human_comment) do
          OpenStruct.new(
            user: OpenStruct.new(login: "viamin"),
            body: "Please also address the logging around the parser fallback path",
            created_at: 55.minutes.ago
          )
        end

        before do
          create(:issue, :pull_request,
            project: project, github_number: 42,
            labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
          create(:agent_run, :completed,
            project: project, source_pull_request_number: 42,
            completed_at: 2.hours.ago)
          stub_github_for_pr(
            recent_issue_comments: recent_page,
            recent_multi_page: true,
            issue_comments: [ human_comment ] + recent_page
          )
        end

        it "falls back to full pagination and detects the earlier comment" do
          result = activity.execute(project_id: project.id)

          expect(result[:prs_to_trigger].size).to eq(1)
          trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
          expect(trigger_types).to include("conversation_comments")
        end
      end
    end

    context "when the new comment is a paid agent update" do
      let(:comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "#{Activities::CompleteExistingPrRunActivity::COMMENT_MARKER}\n## Agent Update\n\nRefreshed the tests and pushed the fix.",
          created_at: 30.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(issue_comments: [ comment ])
      end

      it "ignores the comment" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when short comments are ignored" do
      let(:short_comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "+1",
          created_at: 30.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(issue_comments: [ short_comment ])
      end

      it "does not trigger for short comments" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when there are changes_requested reviews from trusted users" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED", body: "", submitted_at: Time.current }
          ]
        )
      end

      it "detects changes_requested reviews" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("changes_requested")
      end
    end

    context "when a subsequent approved review clears changes_requested" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED", body: "", submitted_at: 2.hours.ago },
            { id: 2, user_login: "viamin", state: "APPROVED", body: "", submitted_at: 1.hour.ago }
          ]
        )
      end

      it "does not trigger when the latest review is approved" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when changes_requested review is older than the last completed agent run" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED", body: "", submitted_at: 2.hours.ago }
          ]
        )
      end

      it "does not trigger for reviews older than the last agent run" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when actionable labels are present" do
      before do
        project.update!(pr_action_labels: [ "paid-rework" ])
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-rework" ], paid_state: "completed")
        stub_github_for_pr
      end

      it "detects actionable labels and returns them for removal" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("actionable_labels")
        expect(trigger[:labels_to_remove]).to eq([ "paid-rework" ])
      end
    end

    context "when PR has merge conflicts and auto_fix is enabled" do
      before do
        project.update!(auto_fix_merge_conflicts: true)
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(mergeable: false)
      end

      it "detects merge conflicts" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("merge_conflicts")
      end
    end

    context "when merge conflicts exist but auto_fix is disabled" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(mergeable: false)
      end

      it "does not trigger for merge conflicts when disabled" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when a ready paid-ready PR has merge conflicts and auto_fix is enabled" do
      before do
        project.update!(auto_fix_merge_conflicts: true)
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-ready" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(mergeable: false)
      end

      it "triggers a ready-phase follow-up for merge conflicts" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("ready")
        expect(trigger[:triggers].first[:type]).to eq("merge_conflicts")
      end
    end

    context "when an active agent run already exists" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "in_progress")
        create(:agent_run, :running,
          project: project, source_pull_request_number: 42)
      end

      it "skips the PR" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when only a review-goal agent run is active" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        create(:agent_run, :running,
          project: project, source_pull_request_number: 42, goal: "review")
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "does not skip the PR" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).not_to be_empty
      end
    end

    context "when followup limit is reached" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed",
          pr_followup_count: 3)
        stub_github_for_pr
      end

      it "skips the PR" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when review threads are from untrusted users" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "stranger" } ]
            }
          ]
        )
      end

      it "does not trigger for untrusted review threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when review threads are from bot users" do
      before do
        project.update!(allowed_github_usernames: [ "viamin", "github-actions[bot]" ])
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr(
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Auto review", path: "app/model.rb", line: 10, author: "github-actions[bot]" } ]
            }
          ]
        )
      end

      it "does not trigger for bot review threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when the initial run (not a follow-up) created the PR" do
      let(:comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "Please fix the error handling in the parser module",
          created_at: 30.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        # Initial run used issue_id (not source_pull_request_number) but
        # recorded pull_request_number on completion.
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: nil,
          pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(issue_comments: [ comment ])
      end

      it "uses the initial run's completed_at as cutoff for comments" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("conversation_comments")
      end

      it "ignores comments older than the initial run" do
        old_comment = OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "This comment was posted before the agent ran successfully",
          created_at: 2.hours.ago
        )
        stub_github_for_pr(issue_comments: [ old_comment ])

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when returning trigger data" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed",
          pr_followup_count: 1)
        stub_github_for_pr(
          checks: [
            { name: "rspec", conclusion: "failure" },
            { name: "rubocop", conclusion: "success" }
          ]
        )
      end

      it "includes current_followup_count for idempotent recording" do
        result = activity.execute(project_id: project.id)

        trigger = result[:prs_to_trigger].first
        expect(trigger[:current_followup_count]).to eq(1)
      end
    end

    # --- Draft phase scanning ---

    context "when PR is in draft phase with Copilot review threads" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "copilot", state: "COMMENTED",
                     body: "I found some issues.", submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "copilot" } ]
            }
          ]
        )
      end

      it "detects Copilot review threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
      end
    end

    context "when review bot review had comments but all threads are resolved" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [],
          reviews: [ { id: 1, user_login: "copilot", state: "COMMENTED",
                     body: "I found some issues.", submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "treats the review as effectively clean and advances to ready_for_owner" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "ready_for_owner" ])
      end
    end

    context "when copilot review had comments but all threads resolved (body-only regression)" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "copilot", state: "COMMENTED",
                     body: "I found some issues.", submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "still treats Copilot resolved-threads as clean and does not trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when codex posted a clean signal as an issue comment with no prior review" do
      before do
        enable_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 30.minutes.ago
        )
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [],
          review_threads: [],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "treats the codex clean comment as a clean bot signal and emits no review_bot triggers" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when a codex clean comment supersedes an older non-clean codex review" do
      before do
        enable_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 10.minutes.ago
        )
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector[bot]", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 2.hours.ago } ],
          review_threads: [],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "treats the bot as clean because the clean comment is newer than the non-clean review" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when a clean codex comment is followed by a newer informational codex comment" do
      before do
        enable_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector"),
          body: "Codex Review: Didn't find any major issues. Hooray!",
          created_at: 10.minutes.ago
        )
        info_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector"),
          body: "To use Codex here, create an environment for this repo.",
          created_at: 5.minutes.ago
        )
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [],
          recent_issue_comments: [ clean_comment, info_comment ]
        )
      end

      it "still treats the bot as clean because later informational comments do not invalidate the clean signal" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when codex and paid_agent are both enabled and only codex posted a clean comment" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "methods" => {
              "codex" => { "enabled" => true },
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector"),
          body: "Codex Review: Didn't find any major issues. Hooray!",
          created_at: 10.minutes.ago
        )
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Found issues that still need fixes.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "does not let codex's clean comment suppress paid_agent feedback" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when codex and paid_agent are both enabled and codex clears codex-owned feedback" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "methods" => {
              "codex" => { "enabled" => true },
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector"),
          body: "Codex Review: Didn't find any major issues. Hooray!",
          created_at: 10.minutes.ago
        )
        info_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector"),
          body: "To use Codex here, create an environment for this repo.",
          created_at: 5.minutes.ago
        )
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [],
          recent_issue_comments: [ clean_comment, info_comment ]
        )
      end

      it "treats codex's clean comment as authoritative for codex-owned feedback" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when a project enables both Copilot and Codex and Copilot has unresolved threads" do
      before do
        enable_copilot_and_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 5.minutes.ago
        )
        # Copilot reviewed the PR with findings; the unresolved Copilot thread
        # must NOT be silently dropped just because Codex separately commented
        # clean. The two bots' state is independent.
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 5 out of 5 changed files and generated 2 comments.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10,
                          author: "copilot-pull-request-reviewer[bot]" } ]
            }
          ],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "still emits review_bot_threads from Copilot — codex's clean comment cannot speak for Copilot" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).to include("review_bot_threads", "review_bot_review_pending")
      end
    end

    context "when Codex and Copilot are both enabled and only Codex signals clean via comment" do
      before do
        enable_copilot_and_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 5.minutes.ago
        )
        # Codex left a non-clean review, then posted a clean comment.
        # Copilot has NOT reviewed at all. The pending trigger for Copilot
        # must still fire — Codex's clean comment cannot speak for Copilot.
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector[bot]", state: "COMMENTED",
                     body: "Found 2 issues.", submitted_at: 10.minutes.ago } ],
          review_threads: [],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "still emits review_bot_review_pending for the missing Copilot review" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).to include("review_bot_review_pending")
      end
    end

    context "when an older codex clean comment is followed by a newer non-clean codex review" do
      before do
        enable_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        stale_clean = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 3.hours.ago
        )
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector[bot]", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [],
          recent_issue_comments: [ stale_clean ]
        )
      end

      it "still emits review_bot_comments because the clean comment is older than the new non-clean review" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when codex posted a clean comment but codex is not an enabled review bot" do
      before do
        # Do NOT call enable_codex_review! — project has no review bots enabled
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 30.minutes.ago
        )
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [],
          review_threads: [],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "does not treat the clean comment as a bypass since the bot is not enabled" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when codex posted a body-only review with no last agent run" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "emits a review_bot_comments trigger because the feedback is unaddressed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments", "review_bot_review_pending")
      end
    end

    context "when codex posted a body-only review before the last agent run completed" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 2.hours.ago } ],
          review_threads: []
        )
      end

      it "treats the review as already addressed and does not trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when a draft PR has a codex body-only review post-dating the last agent run" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 30.minutes.ago } ],
          review_threads: []
        )
      end

      it "emits draft-phase triggers for the unaddressed codex review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_comments")
      end
    end

    context "when codex posted a body-only review after the last agent run completed" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 30.minutes.ago } ],
          review_threads: []
        )
      end

      it "emits a review_bot_comments trigger because the feedback is unaddressed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when codex review pre-dates last run but diff does not touch reviewed files" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "chatgpt-codex-connector", body: "Fix this",
             created_at: 2.hours.ago, path: "app/services/fetch_issues_activity.rb",
             pull_request_review_id: 1 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "db/schema.rb" ])
      end

      it "treats the review as unaddressed because the changed files are unrelated" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments", "review_bot_review_pending")
      end
    end

    context "when codex review pre-dates last run and diff touches a reviewed file" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "chatgpt-codex-connector", body: "Fix this",
             created_at: 2.hours.ago, path: "app/services/fetch_issues_activity.rb",
             pull_request_review_id: 1 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "app/services/fetch_issues_activity.rb", "db/schema.rb" ])
      end

      it "treats the review as addressed because the diff touches the reviewed file" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when codex review pre-dates last run and has no inline comments" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([])
      end

      it "keeps the review actionable because empty review paths cannot prove it was addressed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments", "review_bot_review_pending")
      end
    end

    context "when codex review pre-dates last run and compare API raises GithubClient::Error" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "chatgpt-codex-connector", state: "COMMENTED",
                     body: "Here are some automated review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "chatgpt-codex-connector", body: "Fix this",
             created_at: 2.hours.ago, path: "app/services/fetch_issues_activity.rb",
             pull_request_review_id: 1 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_raise(GithubClient::Error, "Not Found")
      end

      it "falls back to treating the review as addressed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when paid_agent review has inline comments and HEAD equals reviewed commit" do
      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "abc123" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "paid-code-reviewer[bot]", body: "Fix this",
             created_at: 2.hours.ago, path: "app/services/fetch_issues_activity.rb",
             pull_request_review_id: 1 }
          ])
      end

      it "treats the review as unaddressed and emits only the paid_agent_review_pending gate (#1152)" do
        result = activity.execute(project_id: project.id)

        # Gate: a pending paid_agent review suppresses every other trigger so
        # the scanner enqueues exactly one run (the review) per cycle. Bot
        # comments and bot-review-pending are real signals but would route to
        # a create_pr follow-up that collides with the review on /workspace.
        # They will be re-detected on the next scan after the review posts.
        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to eq([ "paid_agent_review_pending" ])
      end
    end

    context "when restarted phase with review completed on current HEAD and no create_pr in cycle" do
      before do
        enable_paid_agent_review!
        _issue = create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          review_goal_retry_reset_at: 1.hour.ago)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "review",
          trigger_type: "automatic",
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 30.minutes.ago, commit_id: "abc123" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "paid-code-reviewer[bot]", body: "Fix this",
             created_at: 30.minutes.ago, path: "lib/agent_harness/providers/github_copilot.rb",
             pull_request_review_id: 1 }
          ])
      end

      it "does not emit paid_agent_review_pending to avoid review loop (#1152)" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("paid_agent_review_pending")
      end
    end

    context "when paid_agent posted a body-only review with no last agent run" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "emits a review_bot_comments trigger because the feedback is unaddressed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments", "review_bot_review_pending")
      end
    end

    context "when paid_agent posted a body-only review before the last agent run completed" do
      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([])
      end

      it "queues only the paid_agent review run; bot comments are re-detected next cycle" do
        result = activity.execute(project_id: project.id)

        # See the gate rationale in the #1152 test above.
        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to eq([ "paid_agent_review_pending" ])
      end
    end

    describe "paid_agent_review_pending hard gate" do
      # Regression coverage for the scheduler bug where each scan cycle emitted
      # both a review run and a create_pr follow-up for the same PR, causing
      # WorktreeConflict failures on /workspace. The gate ensures exactly one
      # actionable trigger per PR per cycle when a paid_agent review is pending.

      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "create_pr",
          trigger_type: "automatic",
          completed_at: 30.minutes.ago)
      end

      it "suppresses ci_failure when a paid_agent review is pending in ready phase" do
        stub_github_for_pr(
          checks: [ { name: "rspec", conclusion: "failure" } ],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to eq([ "paid_agent_review_pending" ])
      end

      it "does not gate when there is no paid_agent review pending (review already complete)" do
        # A subsequent completed review with no new code changes clears the
        # pending trigger, so ci_failure should pass through unimpeded.
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "review",
          trigger_type: "automatic",
          completed_at: 10.minutes.ago)
        stub_github_for_pr(
          checks: [ { name: "rspec", conclusion: "failure" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Generated no new comments. <!-- paid-review-clean -->",
                     submitted_at: 5.minutes.ago, commit_id: "abc123" } ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("ci_failure")
        expect(trigger_types).not_to include("paid_agent_review_pending")
      end
    end

    context "when paid_agent review pre-dates the last run and the diff touches reviewed files" do
      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "create_pr",
          trigger_type: "automatic",
          completed_at: 30.minutes.ago)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "review",
          trigger_type: "automatic",
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "paid-code-reviewer[bot]", body: "Fix this",
             created_at: 2.hours.ago, path: "app/services/fetch_issues_activity.rb",
             pull_request_review_id: 1 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "app/services/fetch_issues_activity.rb", "db/schema.rb" ])
      end

      it "requests a fresh paid_agent review instead of treating the old review as clean" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("ready_for_owner")
      end
    end

    context "when paid_agent review pre-dates last run and inline comments were not addressed" do
      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "create_pr",
          trigger_type: "automatic",
          completed_at: 30.minutes.ago)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "review",
          trigger_type: "automatic",
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "paid-code-reviewer[bot]", body: "Fix this",
             created_at: 2.hours.ago, path: "app/models/agent_run.rb",
             pull_request_review_id: 1 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "app/services/other_service.rb", "db/schema.rb" ])
      end

      it "queues only the paid_agent review run; bot comments are re-detected next cycle" do
        result = activity.execute(project_id: project.id)

        # See the gate rationale in the #1152 test above.
        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to eq([ "paid_agent_review_pending" ])
      end
    end

    context "when paid_agent review is unaddressed but review rounds are exhausted" do
      before do
        enable_paid_agent_review!(max_review_rounds: 1)
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "create_pr",
          trigger_type: "automatic",
          completed_at: 30.minutes.ago)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          goal: "review",
          trigger_type: "automatic",
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 2.hours.ago, commit_id: "rev_sha" } ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([])
      end

      it "does not emit paid_agent_review_pending when rounds are exhausted" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
        expect(trigger_types).not_to include("paid_agent_review_pending")
      end
    end

    context "when paid_agent posted a body-only review after the last agent run completed" do
      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success", status: "completed" } ],
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Here are some review suggestions.",
                     submitted_at: 30.minutes.ago } ],
          review_threads: []
        )
      end

      it "emits a review_bot_comments trigger because the feedback is unaddressed" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when PR is in draft phase with Claude review threads" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "claude[bot]", state: "COMMENTED",
                     body: "I found some issues.", submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "claude[bot]" } ]
            }
          ]
        )
      end

      it "detects Claude review threads as review bot threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
      end
    end

    context "when PR is in draft phase with Claude Code review threads" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "claude-code[bot]", state: "COMMENTED",
                     body: "I found some issues.", submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "claude-code[bot]" } ]
            }
          ]
        )
      end

      it "detects Claude Code review threads as review bot threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
      end
    end

    context "when address_all_bot_reviews is enabled and a non-configured bot has a body-only review" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Here are some suggestions.", submitted_at: 30.minutes.ago }
          ],
          review_threads: []
        )
      end

      it "detects the non-configured bot review and emits review_bot_comments" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and a non-configured bot has unresolved threads" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago }
          ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "claude-code[bot]" } ]
            }
          ]
        )
      end

      it "detects non-configured bot threads and emits review_bot_threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_threads", "review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and a non-configured bot has thread-only feedback without a review object" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "chatgpt-codex-connector" } ]
            }
          ]
        )
      end

      it "detects non-configured bot threads even without a matching review object" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_threads")
      end
    end

    context "when address_all_bot_reviews is disabled and a non-configured bot has comments" do
      before do
        enable_copilot_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Here are some suggestions.", submitted_at: 30.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "ignores the non-configured bot review" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and non-configured bot review predates last agent run and diff touches a reviewed file" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Some old feedback.", submitted_at: 2.hours.ago, commit_id: "rev_sha" }
          ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "chatgpt-codex-connector", body: "Fix this",
             created_at: 2.hours.ago, path: "app/model.rb", pull_request_review_id: 2 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "app/model.rb" ])
      end

      it "does not emit triggers for the already-addressed non-configured bot review" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and non-configured bot review predates last agent run but diff misses reviewed files" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 1)
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Some old feedback.", submitted_at: 2.hours.ago, commit_id: "rev_sha" }
          ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "chatgpt-codex-connector", body: "Fix this",
             created_at: 2.hours.ago, path: "app/model.rb", pull_request_review_id: 2 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "app/other_file.rb" ])
      end

      it "keeps the non-configured bot feedback actionable" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and non-configured bot review is clean" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Codex reviewed 3 files and generated no new comments.", submitted_at: 30.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "does not emit triggers for clean non-configured bot reviews" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and the configured bot has stale feedback but a newer non-configured bot is clean" do
      before do
        enable_paid_agent_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Please tighten the error handling.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Codex reviewed 3 files and generated no new comments.", submitted_at: 30.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "keeps the configured bot feedback actionable" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and a non-enabled body-only bot posts a clean comment superseding an older review" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 10.minutes.ago
        )
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector[bot]", state: "COMMENTED",
             body: "Here are some suggestions.", submitted_at: 30.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "does not emit triggers when a clean issue comment supersedes the older non-clean review" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_comments")
      end
    end

    context "when the non-enabled body-only bot review login differs from the clean comment alias" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        clean_comment = OpenStruct.new(
          user: OpenStruct.new(login: "chatgpt-codex-connector[bot]"),
          body: "Codex Review: Didn't find any major issues. Bravo.",
          created_at: 10.minutes.ago
        )
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Here are some suggestions.", submitted_at: 30.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ],
          recent_issue_comments: [ clean_comment ]
        )
      end

      it "treats provider aliases as the same bot for clean comment supersession" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and multiple non-configured bots have reviews" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Codex reviewed 3 files and generated no new comments.", submitted_at: 45.minutes.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Please fix the error handling.", submitted_at: 30.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "detects actionable reviews from each non-configured bot independently" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when address_all_bot_reviews is enabled and one non-configured bot is clean but another has feedback" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Codex reviewed 3 files and generated no new comments.", submitted_at: 30.minutes.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Please fix the error handling.", submitted_at: 20.minutes.ago }
          ],
          review_threads: [],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "still detects the actionable bot review even though another bot is clean" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when paid_agent rounds are exhausted but the remaining blocker is a non-enabled bot" do
      before do
        enable_paid_agent_review!(max_review_rounds: 1)
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "<!-- PAID_AGENT_REVIEW_STATUS: clean -->", submitted_at: 1.hour.ago },
            { id: 2, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Here are some suggestions.", submitted_at: 30.minutes.ago }
          ],
          review_threads: []
        )
      end

      it "does not escalate to owner" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when review bot review body says generated no comments but unresolved bot threads remain" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 5 out of 5 changed files and generated no comments.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Old comment", path: "app/model.rb", line: 10, author: "copilot-pull-request-reviewer[bot]" } ]
            }
          ]
        )
      end

      it "still returns review_bot_threads because unresolved bot feedback remains" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).to include("review_bot_threads", "review_bot_review_pending")
      end
    end

    context "when no requestable review bot is configured and no reviews exist" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "does not emit a review_bot_review_pending trigger that nothing can satisfy" do
        # Regression: previously the scanner emitted a pending trigger with
        # request_login=nil, which the workflow then skipped via the
        # `if login; request_review(...); end` guard in
        # handle_review_bot_review_pending, wedging the PR in draft forever.
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending")
      end
    end

    context "when paid_agent is the only review method and stale copilot reviews exist" do
      before do
        enable_paid_agent_review!
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 100, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot found issues.", submitted_at: 1.day.ago } ],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "ignores stale copilot reviews and does not emit review_bot triggers" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_comments", "review_bot_threads")
      end
    end

    context "when no review bot review exists and CI is green" do
      before do
        enable_copilot_review!
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "keeps the PR in draft and requests a bot review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end
    end

    context "when address_all_bot_reviews is enabled and no bot reviews exist" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "still requests review from the configured bot only" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first[:triggers].sole
        expect(trigger[:type]).to eq("review_bot_review_pending")
        expect(trigger[:request_login]).to eq(Activities::RequestReviewActivity::COPILOT_LOGIN)
        expect(trigger[:request_logins]).to eq([ Activities::RequestReviewActivity::COPILOT_LOGIN ])
      end
    end

    context "when both copilot and codex are enabled and no bot reviews exist" do
      before do
        enable_copilot_and_codex_review!
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(reviews: [])
      end

      it "emits the full bot chain in request_logins for fallback in RequestReviewActivity" do
        result = activity.execute(project_id: project.id)

        trigger = result[:prs_to_trigger].first[:triggers].find { |t| t[:type] == "review_bot_review_pending" }
        expect(trigger).not_to be_nil
        expect(trigger[:request_logins]).to eq([
          Activities::RequestReviewActivity::COPILOT_LOGIN,
          Activities::RequestReviewActivity::CODEX_LOGIN
        ])
        # Single request_login is preserved for in-flight workflow histories
        # whose code pre-dates the chain field. It is the chain head.
        expect(trigger[:request_login]).to eq(Activities::RequestReviewActivity::COPILOT_LOGIN)
      end
    end

    context "when review bot data cannot be fetched and CI is green" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(draft: true)
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "GitHub review API unavailable")
      end

      it "does not advance the PR out of draft" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when address_all_bot_reviews is enabled and review fetch fails but non-configured bot threads exist" do
      before do
        enable_copilot_review!
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "chatgpt-codex-connector" } ]
            }
          ]
        )
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "GitHub review API unavailable")
      end

      it "keeps the non-configured bot thread actionable" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
      end
    end

    context "when review_threads API fails and bot review has comments" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 3 out of 5 changed files and generated 2 comments.",
                     submitted_at: 1.hour.ago } ]
        )
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "GitHub review threads API unavailable")
      end

      it "treats threads as unknown and returns review_bot_review_pending" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_review_pending")
      end
    end

    context "when no review bot review exists and CI is failing" do
      before do
        enable_copilot_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [],
          checks: [ { name: "rspec", conclusion: "failure" } ]
        )
      end

      it "includes review_bot_review_pending alongside CI failure" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("ci_failure")
        expect(trigger_types).to include("review_bot_review_pending")
      end
    end

    context "when review bot review has non-clean body" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 3 out of 3 changed files and generated 2 comments.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "copilot-pull-request-reviewer[bot]" } ]
            }
          ]
        )
      end

      it "includes review_bot comments and thread triggers" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_comments")
        expect(trigger_types).to include("review_bot_threads")
      end
    end

    context "when paid_agent review includes the clean marker" do
      before do
        enable_paid_agent_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Looks good. <!-- paid-review-clean -->",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "treats the review as clean and emits no review_bot triggers" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when paid_agent review does not include a clean signal" do
      before do
        enable_paid_agent_review!
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Found a few things to fix in the error handling.",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "emits body-only review triggers instead of bypassing via clean signal" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        # The non-clean body-only review is detected as unaddressed feedback,
        # emitting review_bot_comments — proving the clean signal bypass was
        # not triggered and the body-only anti-loop guard correctly flags the
        # review for followup.
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when a newer non-clean review follows an older clean paid_agent review" do
      before do
        enable_paid_agent_review!
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Looks good. <!-- paid-review-clean -->",
             submitted_at: 2.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found new issues after the latest push.",
             submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "does not treat the review as clean because the latest review is non-clean" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        # The latest non-clean body-only review is detected as unaddressed
        # feedback, emitting review_bot_comments — proving the older clean
        # signal did not bypass and the body-only anti-loop guard correctly
        # flags the review for followup.
        expect(trigger_types).to include("review_bot_comments")
      end
    end

    context "when paid_agent is enabled alongside copilot and copilot has unresolved threads" do
      before do
        proj = project
        proj.update!(review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "copilot" => { "enabled" => true }
          }
        })
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Looks good. <!-- paid-review-clean -->",
             submitted_at: 30.minutes.ago },
            { id: 2, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed 3 out of 5 changed files and generated 2 comments.",
             submitted_at: 1.hour.ago }
          ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10,
                          author: "copilot-pull-request-reviewer[bot]" } ]
            }
          ]
        )
      end

      it "still emits review_bot_threads from Copilot — paid_agent clean signal cannot suppress other bots" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).to include("review_bot_threads", "review_bot_review_pending")
      end
    end

    context "when paid_agent clean signal present but paid_agent is not enabled" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
                     body: "Looks good. <!-- paid-review-clean -->",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "ignores the clean signal because paid_agent is not an enabled review method" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending", "review_bot_comments")
      end
    end

    context "when paid_agent review round limit is reached in draft phase" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 3 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "More issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "escalates to owner instead of continuing review cycle" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("paid_agent review round limit")
        expect(trigger[:triggers].first[:details]).to include("3 rounds")
      end
    end

    context "when paid_agent review round limit is reached but the latest review is clean" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 3 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Looks good. <!-- paid-review-clean -->", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "advances to ready_for_owner instead of escalating" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("ready_for_owner")
        expect(trigger[:triggers].map { |t| t[:type] }).not_to include("escalate_to_owner")
      end
    end

    context "when paid_agent review rounds are below the limit in draft phase" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 3 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 2.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "continues the review cycle normally" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when paid_agent max_review_rounds is not set" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => nil, "stop_when_no_comments" => true }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "More issues.", submitted_at: 1.hour.ago },
            { id: 4, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Yet more issues.", submitted_at: 30.minutes.ago }
          ],
          review_threads: []
        )
      end

      it "does not enforce a review round limit" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when reviews are globally disabled but paid_agent method is enabled with max_review_rounds" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => false,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 2.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "does not enforce paid_agent round limits or escalate" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when review is enabled with paid_agent but enabled_review_bot_logins returns empty" do
      before do
        enable_paid_agent_review!(max_review_rounds: 1)
        project.update!(owner_reviewer_login: "viamin")
        # Simulate an edge case where enabled_review_bot_logins resolves to
        # an empty set (e.g. provider support mapping is missing). The
        # allowed_review_bot_logins helper returns Set.new instead of nil,
        # so latest_allowed_bot_review matches nothing and
        # paid_agent_is_latest_blocker? correctly returns false — no
        # escalation occurs.
        allow(Project).to receive(:find_by).and_call_original
        allow(Project).to receive(:find_by).with(id: project.id).and_wrap_original do |_m, **_kw|
          project.tap { |p| allow(p).to receive(:enabled_review_bot_logins).and_return(Set.new) }
        end
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 3)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "does not escalate because no bot matches the empty allowed set" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when paid_agent review round limit is reached and no review exists yet (ready phase)" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          max_pr_followup_runs: 10,
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 2.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "does not emit review_bot_review_pending when round limit is reached" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("review_bot_review_pending")
      end
    end

    context "when paid_agent max_review_rounds is stored as a string" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 3 }
              }
            }
          }
        )
        settings = project.review_settings.deep_merge(
          "methods" => { "paid_agent" => { "termination" => { "max_review_rounds" => "3" } } }
        )
        project.update_column(:review_settings, settings)

        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "More issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "coerces the value and escalates correctly" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("paid_agent review round limit")
      end
    end

    context "when paid_agent rounds are exhausted but a non-paid_agent bot is the latest blocker" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              },
              "copilot" => {
                "enabled" => true
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        copilot_thread = {
          is_resolved: false,
          comments: [ { author: "copilot-pull-request-reviewer[bot]", body: "Please fix this" } ]
        }
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot found issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: [ copilot_thread ]
        )
      end

      it "does not escalate because the blocking review is from copilot, not paid_agent" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when paid_agent is the latest reviewer but copilot has unresolved threads" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              },
              "copilot" => {
                "enabled" => true
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        copilot_thread = {
          is_resolved: false,
          comments: [ { author: "copilot-pull-request-reviewer[bot]", body: "Please fix this" } ]
        }
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: [ copilot_thread ]
        )
      end

      it "does not escalate because copilot threads are a non-paid_agent blocker" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when paid_agent rounds are exhausted in a paid_agent + codex project (no copilot)" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              },
              "codex" => {
                "enabled" => true
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 2.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "does not escalate because codex can continue the automated review cycle" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when paid_agent rounds are exhausted and thread data is unavailable (API failure)" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "paid_agent" => {
                "enabled" => true,
                "termination" => { "max_review_rounds" => 2 }
              }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 1)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 2.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 1.hour.ago }
          ]
        )
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "GitHub review threads API unavailable")
      end

      it "keeps pending status and does not escalate" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).not_to include("escalate_to_owner")
        expect(trigger_types).to include("review_bot_review_pending")
      end
    end

    context "when draft PR has CI green and no Copilot threads" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: []
        )
      end

      it "returns ready_for_owner trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
        expect(trigger[:owner_reviewer_login]).to eq("viamin")
      end
    end

    context "when draft PR has green CI and only resolved bot threads from a non-clean review" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 9 out of 9 changed files and generated 2 comments.",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "advances to ready_for_owner since all bot threads are resolved" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
        expect(trigger[:owner_reviewer_login]).to eq("viamin")
      end
    end

    context "when draft PR has manual-only review and CI is green but reviewer has not approved" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "manual" => { "enabled" => true, "reviewer_login" => "alice" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )
      end

      it "does not emit ready_for_owner; emits manual_review_pending" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        types = trigger[:triggers].map { |t| t[:type] }
        expect(types).to include("manual_review_pending")
        expect(types).not_to include("ready_for_owner")
        pending_trigger = trigger[:triggers].find { |t| t[:type] == "manual_review_pending" }
        expect(pending_trigger[:reviewer_login]).to eq("alice")
      end
    end

    context "when draft PR has manual-only review and configured reviewer has approved" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "manual" => { "enabled" => true, "reviewer_login" => "alice" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 1, user_login: "alice", state: "APPROVED", body: "LGTM",
             submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "emits ready_for_owner when reviewer has approved" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end
    end

    context "when draft PR manual reviewer posts CHANGES_REQUESTED after earlier APPROVED" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "manual" => { "enabled" => true, "reviewer_login" => "alice" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 1, user_login: "alice", state: "APPROVED", body: "LGTM",
             submitted_at: 2.hours.ago },
            { id: 2, user_login: "alice", state: "CHANGES_REQUESTED", body: "Actually, needs fixes",
             submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "uses latest review state and emits manual_review_pending" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        types = trigger[:triggers].map { |t| t[:type] }
        expect(types).to include("manual_review_pending")
        expect(types).not_to include("ready_for_owner")
      end
    end

    context "when draft PR has ci_action-only review and configured action is missing from checks" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "e2e-suite" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )
      end

      it "does not advance; emits ci_action_pending" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        types = trigger[:triggers].map { |t| t[:type] }
        expect(types).to include("ci_action_pending")
        expect(types).not_to include("ready_for_owner")
        pending_trigger = trigger[:triggers].find { |t| t[:type] == "ci_action_pending" }
        expect(pending_trigger[:action_name]).to eq("e2e-suite")
        expect(pending_trigger[:dispatch_required]).to be(false)
      end
    end

    context "when draft PR has Claude ci_action review and the check is still missing on the first scan" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "Claude Code Review" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )
      end

      it "marks the missing Claude check as dispatch_required without stamping state" do
        result = activity.execute(project_id: project.id)

        pending_trigger = result[:prs_to_trigger].first[:triggers].find { |t| t[:type] == "ci_action_pending" }
        expect(pending_trigger[:dispatch_required]).to be(true)

        issue = Issue.find_by(github_number: 42)
        expect(issue.ci_action_dispatched_at).to be_nil
      end
    end

    context "when draft PR has Claude ci_action review and a recent scan already requested dispatch" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0,
          ci_action_dispatched_at: 1.minute.ago)
      end

      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "Claude Code Review" } }
          }
        )
        pr_issue
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )
      end

      it "suppresses redispatch until the grace window expires" do
        result = activity.execute(project_id: project.id)

        pending_trigger = result[:prs_to_trigger].first[:triggers].find { |t| t[:type] == "ci_action_pending" }
        expect(pending_trigger[:dispatch_required]).to be(false)
      end
    end

    context "when draft PR is fork-backed and Claude ci_action review is enabled" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "Claude Code Review" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          head_repo_fork: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )
      end

      it "does not emit a blocking ci_action_pending trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end
    end

    context "when draft PR has ci_action-only review and configured action succeeded" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "e2e-suite" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "e2e-suite", conclusion: "success" }
          ],
          reviews: [],
          review_threads: []
        )
      end

      it "advances to ready_for_owner" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end
    end

    context "when draft PR has ci_action-only review and the configured action has surrounding whitespace" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => " e2e-suite " } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "e2e-suite", conclusion: "success" }
          ],
          reviews: [],
          review_threads: []
        )
      end

      it "treats the matching check as complete" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end
    end

    context "when ready PR has manual review pending and auto-merge is enabled" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
      end

      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          review_settings: {
            "enabled" => true,
            "methods" => { "manual" => { "enabled" => true, "reviewer_login" => "alice" } }
          }
        )
        pr_issue
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "Approved",
             submitted_at: 1.hour.ago }
          ],
          review_threads: []
        )
      end

      it "does not auto-merge when manual reviewer has not approved" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).not_to be_empty
        trigger = result[:prs_to_trigger].first
        types = trigger[:triggers].map { |t| t[:type] }
        expect(types).to include("manual_review_pending")
        expect(types).not_to include("owner_approved")
      end
    end

    context "when ready PR is fork-backed and Claude ci_action review is enabled" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "Claude Code Review" } }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
        stub_github_for_pr(
          head_repo_fork: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [ { user_login: "viamin", state: "APPROVED", submitted_at: Time.current } ],
          review_threads: []
        )
      end

      it "allows owner approval to complete without a Claude check run" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end
    end

    context "when detect_ready_triggers includes non-bot review gates" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          pr_followup_count: 0)
      end

      before do
        project.update!(
          owner_reviewer_login: "viamin",
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "e2e-suite" } }
          }
        )
        pr_issue
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )
      end

      it "includes ci_action_pending in ready-phase triggers" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        types = trigger[:triggers].map { |t| t[:type] }
        expect(types).to include("ci_action_pending")
      end
    end

    context "when draft PR has some green checks but others still pending" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [
            { name: "lint", conclusion: "success" },
            { name: "rspec", conclusion: nil }
          ],
          review_threads: []
        )
      end

      it "does not advance to ready while checks are pending" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "does not advance last_pr_scan_at when checks are pending" do
        issue = Issue.find_by(github_number: 42)
        issue.update_columns(last_pr_scan_at: nil, github_updated_at: Time.current)

        expect {
          activity.execute(project_id: project.id)
        }.not_to change { issue.reload.last_pr_scan_at }
      end
    end

    context "when draft PR CI races post-review scan" do
      let!(:draft_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0,
          github_updated_at: 1.hour.ago,
          last_pr_scan_at: nil)
      end

      before do
        project.update!(owner_reviewer_login: "viamin")
      end

      it "does not advance last_pr_scan_at when CI is still in-progress" do
        stub_github_for_pr(
          draft: true,
          checks: [
            { name: "lint", conclusion: "success" },
            { name: "rspec", conclusion: nil }
          ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)
        expect(result[:prs_to_trigger]).to eq([])
        expect(draft_issue.reload.last_pr_scan_at).to be_nil
      end

      it "emits ready_for_owner on second scan after CI finishes green" do
        pending_checks = [ { name: "lint", conclusion: "success" }, { name: "rspec", conclusion: nil } ]
        stub_github_for_pr(draft: true, checks: pending_checks, review_threads: [])
        activity.execute(project_id: project.id)

        green_checks = [ { name: "lint", conclusion: "success" }, { name: "rspec", conclusion: "success" } ]
        stub_github_for_pr(draft: true, checks: green_checks, review_threads: [])

        result = activity.execute(project_id: project.id)
        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ready_for_owner")
        expect(draft_issue.reload.last_pr_scan_at).to be_present
      end

      it "returns :skipped when check fetch fails (checks nil)" do
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: []
        )
        allow(github_client).to receive(:check_runs_for_ref)
          .and_raise(GithubClient::Error.new("API error"))

        expect {
          activity.execute(project_id: project.id)
        }.not_to change { draft_issue.reload.last_pr_scan_at }
      end
    end

    context "when draft review limit is reached" do
      before do
        project.update!(max_draft_review_rounds: 3, owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 3)
        stub_github_for_pr(draft: true)
      end

      it "returns escalate_to_owner trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:current_draft_review_count]).to eq(3)
      end
    end

    context "when consecutive draft follow-up runs all fail without output" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 3)
      end

      before do
        stub_github_for_pr(
          draft: true,
          review_threads: [
            { id: "thread_1", is_resolved: false,
             comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "viamin" } ] }
          ]
        )
      end

      def create_draft_run(status:, iterations:, created_at:, trigger_type: "automatic", goal: "create_pr")
        create(:agent_run,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          trigger_type: trigger_type,
          goal: goal,
          status: status,
          iterations: iterations,
          created_at: created_at)
      end

      it "escalates after 3 consecutive no-output failures with breaker-specific reason" do
        3.times { |i| create_draft_run(status: "timeout", iterations: 0, created_at: i.minutes.ago) }

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("Consecutive draft follow-up failures")
      end

      it "does not escalate when a recent run produced output" do
        create_draft_run(status: "timeout", iterations: 0, created_at: 1.minute.ago)
        create_draft_run(status: "completed", iterations: 5, created_at: 2.minutes.ago)
        create_draft_run(status: "timeout", iterations: 0, created_at: 3.minutes.ago)

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger].first[:triggers]
        expect(triggers.first[:type]).not_to eq("escalate_to_owner")
      end

      it "does not escalate with fewer than 3 consecutive failures" do
        2.times { |i| create_draft_run(status: "timeout", iterations: 0, created_at: i.minutes.ago) }

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger].first[:triggers]
        expect(triggers.first[:type]).not_to eq("escalate_to_owner")
      end

      it "does not count manual or review runs toward the breaker" do
        create_draft_run(status: "timeout", iterations: 0, created_at: 1.minute.ago)
        create_draft_run(status: "failed", iterations: 0, created_at: 2.minutes.ago)
        # This run is manual, not an automatic draft followup
        create_draft_run(status: "timeout", iterations: 0, created_at: 3.minutes.ago, trigger_type: "manual")

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger].first[:triggers]
        expect(triggers.first[:type]).not_to eq("escalate_to_owner")
      end

      it "does not escalate after draft restart even with old failures" do
        # Simulate maybe_restart_draft resetting draft_review_count to 0
        # while old non-draft failures still exist in the DB
        pr_issue.update!(draft_review_count: 0, pr_review_phase: "restarted")
        3.times { |i| create_draft_run(status: "timeout", iterations: 0, created_at: i.minutes.ago) }

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger].first[:triggers]
        expect(triggers.first[:type]).not_to eq("escalate_to_owner")
      end
    end

    context "when a Dependabot-authored PR is in draft phase" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0,
          github_creator_login: "dependabot[bot]")
      end

      it "skips reviews and advances to ready when CI is green" do
        enable_copilot_review!
        stub_github_for_pr(
          draft: true,
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "ready_for_owner" ])
      end

      it "triggers ci_failure follow-up when CI fails" do
        stub_github_for_pr(
          draft: true,
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "failure" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("ci_failure")
      end

      it "does not request reviews even when review is enabled" do
        enable_copilot_review!
        stub_github_for_pr(
          draft: true,
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).not_to include("review_bot_review_pending")
        expect(trigger_types).not_to include("paid_agent_review_pending")
      end

      it "returns nil when CI is still pending" do
        stub_github_for_pr(
          draft: true,
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: nil } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
      end
    end

    context "when a Dependabot-authored PR is in ready phase" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          draft_review_count: 0,
          github_creator_login: "dependabot[bot]")
      end

      it "does not emit owner_approved — auto-merge is handled by DependabotAutoMergeJob" do
        project.update!(auto_merge_mode: "all", owner_reviewer_login: "viamin")
        stub_github_for_pr(
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
      end

      it "does not emit owner_approved in dependabot_only mode" do
        project.update!(auto_merge_mode: "dependabot_only")
        stub_github_for_pr(
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
      end

      it "triggers ci_failure follow-up without requiring reviews" do
        stub_github_for_pr(
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "failure" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("ci_failure")
      end

      it "returns no triggers when CI is green regardless of auto_merge mode" do
        project.update!(auto_merge_mode: "off")
        stub_github_for_pr(
          author_login: "dependabot[bot]",
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: [],
          reviews: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
      end
    end

    context "when consecutive follow-up runs fail with operational errors" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          draft_review_count: 0)
      end

      before do
        stub_github_for_pr(review_threads: [], reviews: [], checks: [])
      end

      def create_followup_run(status:, error_message: nil, created_at: Time.current)
        create(:agent_run,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          trigger_type: "automatic",
          goal: "create_pr",
          status: status,
          error_message: error_message,
          started_at: created_at - 5.minutes,
          completed_at: created_at,
          created_at: created_at)
      end

      it "escalates after 3 consecutive provider exhaustion failures" do
        3.times do |i|
          create_followup_run(
            status: "failed",
            error_message: "All providers exhausted: claude_code, codex",
            created_at: i.minutes.ago
          )
        end

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("Consecutive operational failures")
      end

      it "escalates after 3 consecutive timeout failures" do
        3.times do |i|
          create_followup_run(
            status: "timeout",
            error_message: "wall_clock_timeout: exceeded 30 minutes",
            created_at: i.minutes.ago
          )
        end

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("Consecutive operational failures")
      end

      it "escalates after 3 consecutive mixed operational failures" do
        create_followup_run(status: "timeout", error_message: "wall_clock_timeout", created_at: 1.minute.ago)
        create_followup_run(status: "rate_limited", error_message: "All providers rate limited", created_at: 2.minutes.ago)
        create_followup_run(status: "failed", error_message: "All providers exhausted: claude_code", created_at: 3.minutes.ago)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
      end

      it "does not escalate when a code-level failure breaks the streak" do
        create_followup_run(status: "timeout", error_message: "wall_clock_timeout", created_at: 1.minute.ago)
        create_followup_run(status: "failed", error_message: "An error occurred during execution", created_at: 2.minutes.ago)
        create_followup_run(status: "timeout", error_message: "wall_clock_timeout", created_at: 3.minutes.ago)

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger]
        if triggers.any?
          expect(triggers.first[:triggers].first[:type]).not_to eq("escalate_to_owner")
        end
      end

      it "does not escalate with fewer than 3 consecutive operational failures" do
        2.times do |i|
          create_followup_run(
            status: "failed",
            error_message: "All providers exhausted: claude_code",
            created_at: i.minutes.ago
          )
        end

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger]
        if triggers.any?
          expect(triggers.first[:triggers].first[:type]).not_to eq("escalate_to_owner")
        end
      end

      it "does not re-escalate PRs already in escalated phase" do
        pr_issue.update!(
          pr_review_phase: "escalated",
          labels: pr_issue.labels + [ "paid-escalated" ]
        )
        3.times do |i|
          create_followup_run(
            status: "failed",
            error_message: "All providers exhausted: claude_code",
            created_at: i.minutes.ago
          )
        end

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger]
        escalation_triggers = triggers.select do |t|
          t[:triggers].any? { |tr| tr[:details]&.include?("Consecutive operational failures") }
        end
        expect(escalation_triggers).to be_empty
      end

      it "does not count manual runs toward the breaker" do
        create_followup_run(status: "timeout", error_message: "wall_clock_timeout", created_at: 1.minute.ago)
        create_followup_run(status: "timeout", error_message: "wall_clock_timeout", created_at: 2.minutes.ago)
        create(:agent_run, :timeout,
          project: project,
          issue: pr_issue,
          source_pull_request_number: 42,
          trigger_type: "manual",
          goal: "create_pr",
          error_message: "wall_clock_timeout",
          created_at: 3.minutes.ago)

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger]
        if triggers.any?
          expect(triggers.first[:triggers].first[:type]).not_to eq("escalate_to_owner")
        end
      end

      it "does not immediately re-escalate after the operational reset boundary" do
        pr_issue.update!(operational_failure_reset_at: Time.current)
        3.times do |i|
          create_followup_run(
            status: "failed",
            error_message: "All providers exhausted: claude_code",
            created_at: (i + 1).minutes.ago
          )
        end

        result = activity.execute(project_id: project.id)

        triggers = result[:prs_to_trigger]
        if triggers.any?
          expect(triggers.first[:triggers].first[:type]).not_to eq("escalate_to_owner")
        end
      end

      it "can re-escalate after a fresh post-dismiss streak of operational failures" do
        pr_issue.update!(operational_failure_reset_at: 10.minutes.ago)
        create_followup_run(status: "timeout", error_message: "wall_clock_timeout", created_at: 1.minute.ago)
        create_followup_run(status: "rate_limited", error_message: "All providers rate limited", created_at: 2.minutes.ago)
        create_followup_run(
          status: "failed",
          error_message: "All providers exhausted: claude_code",
          created_at: 3.minutes.ago
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("escalate_to_owner")
      end
    end

    context "when draft PR has unresolved trusted review threads" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "viamin" } ]
            }
          ]
        )
      end

      it "triggers a draft followup for human review threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_threads")
      end
    end

    context "when draft PR has new conversation comments after last run" do
      let(:comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "Please fix the error handling in the parser module",
          created_at: 30.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(draft: true, issue_comments: [ comment ])
      end

      it "triggers a draft followup for new conversation comments" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("conversation_comments")
      end
    end

    context "when the only new comment is Paid's own agent update" do
      let(:comment) do
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "## Agent Update\n\nThe background agent confirmed what we already found.",
          created_at: 30.minutes.ago
        )
      end

      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(
          draft: true,
          issue_comments: [ comment ],
          checks: [ { name: "ci", conclusion: nil } ]
        )
      end

      it "does not treat the agent update as a conversation trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when draft PR has changes_requested review after last run" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago)
        stub_github_for_pr(
          draft: true,
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED", body: "", submitted_at: 30.minutes.ago }
          ]
        )
      end

      it "triggers a draft followup for changes requested" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("changes_requested")
      end
    end

    context "when draft PR has review bot threads from copilot-pull-request-reviewer[bot]" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed and generated 1 comment.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "copilot-pull-request-reviewer[bot]" } ]
            }
          ]
        )
      end

      it "recognizes copilot-pull-request-reviewer[bot] as a review bot" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
      end
    end

    context "when the latest Copilot review uses the real GitHub bot login" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
          draft: true,
          checks: [],
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 20 out of 20 changed files in this pull request and generated 3 comments.",
                     submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "treats the review as effectively clean and advances to ready_for_owner" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "ready_for_owner" ])
      end
    end

    context "when max_draft_review_rounds is zero (skip draft phase)" do
      before do
        enable_copilot_review!
        project.update!(max_draft_review_rounds: 0, owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
      end

      it "still requires a clean bot review before returning ready_for_owner" do
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "does not return ready_for_owner when CI is failing" do
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "failure" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
      end

      it "ignores review threads but still requires a clean bot review when CI is green" do
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "viamin" } ]
            }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "returns review_bot_review_pending when bot review is non-clean even without fetching threads" do
        non_clean_review = { id: 200, user_login: "copilot-pull-request-reviewer[bot]",
                            state: "COMMENTED",
                            body: "Copilot reviewed 3 out of 5 changed files and generated 2 comments.",
                            submitted_at: 1.hour.ago }
        bot_thread = { id: "thread_bot", is_resolved: false,
                      comments: [ { body: "Fix this", path: "app/model.rb", line: 5,
                                  author: "copilot-pull-request-reviewer[bot]" } ] }
        stub_github_for_pr(draft: true, checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [ non_clean_review ], review_threads: [ bot_thread ])

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        # Should be pending (not empty) because threads were not fetched in skip mode
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "returns ready_for_owner when CI is green and the latest bot review is clean" do
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "returns ready_for_owner when the latest bot review is clean and the repo has no checks" do
        stub_github_for_pr(
          draft: true,
          checks: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "does not return ready_for_owner when CI is pending" do
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: nil } ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "detects non-configured bot unresolved threads with address_all_bot_reviews enabled" do
        project.update!(review_settings: project.review_settings.merge("address_all_bot_reviews" => true))
        stub_github_for_pr(
          draft: true,
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 200, user_login: "chatgpt-codex-connector", state: "COMMENTED",
             body: "Codex has reviewed the pull request and determined it is ready to merge.",
             submitted_at: 1.hour.ago }
          ],
          review_threads: [
            { id: "thread_bot", is_resolved: false,
             comments: [ { body: "Fix this", path: "app/model.rb", line: 5,
                         author: "chatgpt-codex-connector" } ] }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }).to include("review_bot_comments")
      end
    end

    # --- Ready phase scanning ---

    context "when owner has approved the PR" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )
      end

      it "returns owner_approved trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end

      it "returns owner_approved when the repo has no checks" do
        stub_github_for_pr(
          checks: [],
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end

      it "does not emit owner_approved when auto_merge is disabled" do
        project.update!(auto_merge_mode: "off")

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "does not emit owner_approved when a dependency PR is not merged" do
        issue = Issue.find_by!(project: project, github_number: 42)
        issue.update!(body: "Depends on #41")
        allow(github_client).to receive(:issue_comments)
          .with(project.full_name, 42)
          .and_return([])
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 41)
          .and_return(OpenStruct.new(number: 41, merged: false, merged_at: nil))

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when owner approved but unresolved human review threads exist" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Critical security vulnerability", path: "app/model.rb", line: 10, author: "viamin" } ]
            }
          ]
        )
      end

      it "does not auto-merge and emits review thread triggers instead" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).not_to include("owner_approved")
        expect(trigger_types).to include("review_threads")
      end
    end

    context "when owner approved but changes_requested exists from trusted user" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all",
          allowed_github_usernames: [ "viamin", "reviewer" ])
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: 1.hour.ago },
            { id: 2, user_login: "reviewer", state: "CHANGES_REQUESTED", body: "Needs work",
             submitted_at: Time.current }
          ]
        )
      end

      it "does not auto-merge" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).not_to include("owner_approved")
        expect(trigger_types).to include("changes_requested")
      end
    end

    context "when owner approved but new conversation comment from trusted user" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        issue = create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        create(:agent_run, project: project, issue: issue,
          pull_request_number: 42, status: "completed",
          completed_at: 2.hours.ago)
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ],
          issue_comments: [
            OpenStruct.new(
              user: OpenStruct.new(login: "viamin"),
              body: "This has a critical security vulnerability that needs to be fixed",
              created_at: 1.hour.ago
            )
          ]
        )
      end

      it "does not auto-merge" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).not_to include("owner_approved")
        expect(trigger_types).to include("conversation_comments")
      end
    end

    context "when owner reviewer is also the PR author" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(author_login: "viamin", reviews: default_clean_copilot_review)
      end

      it "returns owner_approved without a separate owner approval review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end
    end

    context "when the PR author is not the owner reviewer" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(author_login: "someone-else", reviews: default_clean_copilot_review)
      end

      it "still requires an owner approval review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    # --- Stale review detection ---

    context "when owner approved but head commit is newer than approval" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: 2.hours.ago }
          ],
          head_committed_at: 1.hour.ago
        )
      end

      it "blocks auto-merge due to stale review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when owner approved after the latest commit" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: 1.hour.ago }
          ],
          head_committed_at: 2.hours.ago
        )
      end

      it "allows auto-merge (review is fresh)" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end
    end

    context "when owner re-approves after commit but manual reviewer approval is stale" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          allowed_github_usernames: %w[viamin reviewer],
          review_settings: {
            "enabled" => true,
            "methods" => {
              "manual" => { "enabled" => true, "reviewer_login" => "reviewer" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "reviewer", state: "APPROVED", body: "", submitted_at: 3.hours.ago },
            { id: 2, user_login: "viamin", state: "APPROVED", body: "", submitted_at: 30.minutes.ago }
          ],
          head_committed_at: 1.hour.ago
        )
      end

      it "blocks auto-merge because the manual reviewer's approval is stale" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    # --- Blocking review method completeness ---

    context "when ci_action review method is enabled but action has not passed" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "ci_action" => { "enabled" => true, "action_name" => "security-review" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ],
          checks: [ { name: "ci", conclusion: "success" } ]
        )
      end

      it "blocks auto-merge because ci_action check is missing" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("ci_action_pending")
        expect(trigger[:triggers].map { |t| t[:type] }).not_to include("owner_approved")
      end
    end

    context "when ci_action review method is enabled and action has passed" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "ci_action" => { "enabled" => true, "action_name" => "security-review" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ],
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "security-review", conclusion: "success" }
          ]
        )
      end

      it "allows auto-merge when ci_action check passes" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end
    end

    context "when ci_action review method is enabled but action has failed" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          review_settings: {
            "enabled" => true,
            "methods" => {
              "ci_action" => { "enabled" => true, "action_name" => "security-review" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ],
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "security-review", conclusion: "failure" }
          ]
        )
      end

      it "blocks auto-merge because ci_action failed" do
        result = activity.execute(project_id: project.id)

        # ci_failure triggers a followup, not owner_approved
        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("ci_failure")
        expect(trigger_types).not_to include("owner_approved")
      end
    end

    context "when manual review method is enabled but no human has approved" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          allowed_github_usernames: %w[viamin reviewer],
          review_settings: {
            "enabled" => true,
            "methods" => {
              "manual" => { "enabled" => true, "reviewer_login" => "reviewer" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "viamin", state: "COMMENTED", body: "Looks good!", submitted_at: Time.current }
          ]
        )
      end

      it "blocks auto-merge because no APPROVED review exists" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("manual_review_pending")
        expect(trigger[:triggers].map { |t| t[:type] }).not_to include("owner_approved")
      end
    end

    context "when manual review method is enabled and only the owner has approved" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          allowed_github_usernames: %w[viamin reviewer],
          review_settings: {
            "enabled" => true,
            "methods" => {
              "manual" => { "enabled" => true, "reviewer_login" => "reviewer" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )
      end

      it "blocks auto-merge because manual review requires a non-owner approval" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].map { |t| t[:type] }).to include("manual_review_pending")
        expect(trigger[:triggers].map { |t| t[:type] }).not_to include("owner_approved")
      end
    end

    context "when manual review method is enabled and a non-owner human has approved" do
      before do
        project.update!(
          owner_reviewer_login: "viamin",
          auto_merge_mode: "all",
          allowed_github_usernames: %w[viamin reviewer],
          review_settings: {
            "enabled" => true,
            "methods" => {
              "manual" => { "enabled" => true, "reviewer_login" => "reviewer" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current },
            { id: 2, user_login: "reviewer", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )
      end

      it "allows auto-merge when manual review is complete" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end
    end

    # --- Copilot review path regression ---

    context "when copilot review is enabled with unresolved bot threads and owner approved" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        enable_copilot_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
             body: "Copilot reviewed and generated 1 comment.", submitted_at: 1.hour.ago },
            { id: 2, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ],
          review_threads: [
            { id: "thread_1", is_resolved: false,
             comments: [ { body: "Fix this", path: "app/model.rb", line: 10,
                         author: "copilot-pull-request-reviewer[bot]" } ] }
          ]
        )
      end

      it "blocks auto-merge due to unresolved copilot threads" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).not_to include("owner_approved")
        expect(trigger_types).to include("review_bot_threads")
      end
    end

    # --- Codex review path regression ---

    context "when codex review is enabled and review has comments" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        enable_codex_review!
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [
            { id: 1, user_login: "github-actions[bot]", state: "COMMENTED",
             body: "Codex Review: Found 2 issues.", submitted_at: Time.current },
            { id: 2, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )
      end

      it "blocks auto-merge due to non-clean codex review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_bot_review_pending")
        expect(trigger_types).not_to include("owner_approved")
      end
    end

    context "when ready PR has unresolved review bot threads" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer", state: "COMMENTED",
                     body: "Copilot reviewed and generated 1 comment.",
                     submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "copilot-pull-request-reviewer" } ]
            }
          ]
        )
      end

      it "triggers a followup for review bot threads in ready phase" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("ready")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_review_pending")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
      end
    end

    # --- Escalated phase scanning ---

    context "when PR is in escalated phase with CI failures" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
          pr_review_phase: "escalated",
          paid_state: "completed")
        stub_github_for_pr(
          checks: [
            { name: "rspec", conclusion: "failure" }
          ]
        )
      end

      it "detects triggers in escalated phase" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("escalated")
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
      end
    end

    context "when PR is in merged phase" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "merged",
          github_state: "open")
      end

      it "does not scan merged PRs" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    # --- Restarted phase (draft conversion detection) ---

    context "when an escalated PR is converted back to draft on GitHub" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
          pr_review_phase: "escalated",
          draft_review_count: 10,
          pr_followup_count: 3)
      end

      before do
        stub_github_for_pr(draft: true,
          reviews: [ { id: 1, user_login: "copilot", state: "COMMENTED",
                     body: "I found issues.", submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "copilot" } ]
            }
          ])
      end

      it "resets the phase to restarted" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_review_phase).to eq("restarted")
      end

      it "resets draft_review_count to zero" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.draft_review_count).to eq(0)
      end

      it "resets pr_followup_count to zero" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_followup_count).to eq(0)
      end

      it "scans the PR as a draft and returns triggers" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("restarted")
        expect(trigger[:current_draft_review_count]).to eq(0)
      end
    end

    context "when an escalated PR at review-goal retry limit is converted back to draft" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
          pr_review_phase: "escalated",
          draft_review_count: 10,
          pr_followup_count: 3)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 5)
        3.times do
          create(:agent_run,
            project: project, issue: pr_issue,
            source_pull_request_number: 42,
            goal: "review", status: "failed",
            started_at: 1.hour.ago, completed_at: 1.hour.ago)
        end
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "resets the retry breaker and scans the restarted draft instead of re-escalating" do
        result = activity.execute(project_id: project.id)
        pr_issue.reload
        expect(pr_issue.pr_review_phase).to eq("restarted")
        expect(pr_issue.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger[:phase]).to eq("restarted")
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when a ready PR is converted back to draft on GitHub" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          draft_review_count: 5,
          pr_followup_count: 3)
      end

      before do
        stub_github_for_pr(draft: true,
          checks: [ { name: "rspec", conclusion: "failure" } ])
      end

      it "resets the phase to restarted and scans as draft" do
        result = activity.execute(project_id: project.id)

        pr_issue.reload
        expect(pr_issue.pr_review_phase).to eq("restarted")
        expect(pr_issue.draft_review_count).to eq(0)
        expect(pr_issue.pr_followup_count).to eq(0)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("restarted")
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
      end
    end

    context "when a ready PR at review-goal retry limit is converted back to draft" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          draft_review_count: 5,
          pr_followup_count: 3)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 5)
        3.times do
          create(:agent_run,
            project: project, issue: pr_issue,
            source_pull_request_number: 42,
            goal: "review", status: "failed",
            started_at: 1.hour.ago, completed_at: 1.hour.ago)
        end
        stub_github_for_pr(draft: true,
          checks: [ { name: "rspec", conclusion: "failure" } ])
      end

      it "resets the retry breaker and processes the restarted draft" do
        result = activity.execute(project_id: project.id)

        pr_issue.reload
        expect(pr_issue.pr_review_phase).to eq("restarted")
        expect(pr_issue.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger[:phase]).to eq("restarted")
        # paid_agent_review_pending gates the ci_failure trigger in this cycle —
        # the review must run before any create_pr follow-up addresses CI.
        # ci_failure will be re-emitted on the next scan after the review posts.
        expect(trigger_types).to eq([ "paid_agent_review_pending" ])
      end

      it "can emit paid_agent_review_pending again after draft conversion restarts the cycle" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
        expect(trigger_types).to include("paid_agent_review_pending")
      end
    end

    context "when a ready PR exhausted paid_agent review rounds before draft restart" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "ready",
          draft_review_count: 5,
          pr_followup_count: 3)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 3)
        3.times do
          create(:agent_run,
            project: project, issue: pr_issue,
            source_pull_request_number: 42,
            goal: "review", status: "failed",
            started_at: 1.hour.ago, completed_at: 1.hour.ago)
        end
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "re-emits paid_agent_review_pending for the restarted draft cycle" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("ready_for_owner")
      end

      it "ignores unfinished automatic review runs from the pre-restart cycle" do
        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "review",
          status: "running",
          started_at: 30.minutes.ago)

        result = activity.execute(project_id: project.id)

        trigger = result[:prs_to_trigger].first
        pending_trigger = trigger[:triggers].find { |entry| entry[:type] == "paid_agent_review_pending" }

        expect(trigger[:phase]).to eq("restarted")
        expect(pending_trigger[:details]).to eq("No paid_agent review found for PR")
      end
    end

    context "when a draft PR is manually marked ready on GitHub" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 2,
          pr_followup_count: 1)
      end

      before do
        stub_github_for_pr(draft: false,
          checks: [ { name: "ci", conclusion: "failure" } ])
      end

      it "advances the local phase to ready" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_review_phase).to eq("ready")
      end

      it "scans the PR using ready-phase logic" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("ready")
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
      end

      it "preserves existing draft_review_count" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.draft_review_count).to eq(2)
      end
    end

    context "when a restarted PR is manually marked ready on GitHub" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          draft_review_count: 0,
          pr_followup_count: 0)
      end

      before do
        stub_github_for_pr(draft: false,
          checks: [ { name: "ci", conclusion: "failure" } ])
      end

      it "advances the local phase to ready" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_review_phase).to eq("ready")
      end

      it "scans the PR using ready-phase logic" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("ready")
        expect(trigger[:triggers].first[:type]).to eq("ci_failure")
      end
    end

    context "when a draft PR fetch fails during phase reconciliation" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:pull_request)
          .and_raise(GithubClient::Error.new("API error"))
        allow(github_client).to receive(:review_threads)
          .and_raise(GithubClient::Error.new("API error"))
        allow(github_client).to receive(:pull_request_reviews)
          .and_raise(GithubClient::Error.new("API error"))
        allow(github_client).to receive(:recent_issue_comments)
          .and_raise(GithubClient::Error.new("API error"))
      end

      it "keeps the phase as draft" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_review_phase).to eq("draft")
      end
    end

    context "when a restarted PR only has stale pre-restart paid_agent reviews" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          review_goal_retry_reset_at: 1.hour.ago)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 3)
        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "create_pr",
          status: "completed",
          created_at: 40.minutes.ago,
          started_at: 40.minutes.ago,
          completed_at: 30.minutes.ago)
        stub_github_for_pr(
          draft: true,
          reviews: [
            { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Found issues.", submitted_at: 3.hours.ago },
            { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "Still has issues.", submitted_at: 2.hours.ago },
            { id: 3, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
             body: "More issues.", submitted_at: 90.minutes.ago, commit_id: "rev_sha" }
          ],
          review_threads: []
        )
        allow(github_client).to receive(:pull_request_review_comments)
          .with(project.full_name, 42)
          .and_return([
            { id: 10, user_login: "paid-code-reviewer[bot]", body: "Fix this",
             created_at: 90.minutes.ago, path: "app/services/fetch_issues_activity.rb",
             pull_request_review_id: 3 }
          ])
        allow(github_client).to receive(:compare_changed_files)
          .with(project.full_name, "rev_sha", "abc123")
          .and_return([ "app/services/fetch_issues_activity.rb" ])
      end

      it "restarts the review cycle instead of counting the stale reviews against the new draft" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |entry| entry[:type] }

        expect(trigger[:phase]).to eq("restarted")
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("escalate_to_owner")
        expect(trigger_types).not_to include("ready_for_owner")
      end
    end

    context "when a restarted PR has stale failed review runs from before the reset" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          review_goal_retry_reset_at: 1.hour.ago)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 5)

        3.times do |index|
          create(:agent_run, :automatic,
            project: project, issue: pr_issue,
            source_pull_request_number: 42,
            goal: "review", status: "failed",
            created_at: (2.hours.ago + index.minutes),
            started_at: (90.minutes.ago + index.minutes),
            completed_at: (30.minutes.ago + index.minutes))
        end

        stub_github_for_pr(draft: true, reviews: [])
      end

      it "ignores failures that were enqueued before the restart" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |entry| entry[:type] }
        pending_trigger = trigger[:triggers].find { |entry| entry[:type] == "paid_agent_review_pending" }

        expect(trigger[:phase]).to eq("restarted")
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("review_goal_retry")
        expect(trigger_types).not_to include("escalate_to_owner")
        expect(pending_trigger[:details]).to eq("No paid_agent review found for PR")
      end
    end

    context "when a preexisting restarted PR still has a NULL retry reset timestamp" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          review_goal_retry_reset_at: nil)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 5)

        3.times do |index|
          create(:agent_run, :automatic,
            project: project, issue: pr_issue,
            source_pull_request_number: 42,
            goal: "review", status: "failed",
            created_at: (2.hours.ago + index.minutes),
            started_at: (2.hours.ago + index.minutes),
            completed_at: (2.hours.ago + index.minutes))
        end

        stub_github_for_pr(draft: true, reviews: [])
      end

      it "backfills the reset boundary before counting old failures" do
        freeze_time do
          result = activity.execute(project_id: project.id)

          expect(pr_issue.reload.review_goal_retry_reset_at).to be_within(1.second).of(Time.current)
          trigger = result[:prs_to_trigger].first
          trigger_types = trigger[:triggers].map { |entry| entry[:type] }
          pending_trigger = trigger[:triggers].find { |entry| entry[:type] == "paid_agent_review_pending" }

          expect(trigger[:phase]).to eq("restarted")
          expect(trigger_types).to include("paid_agent_review_pending")
          expect(trigger_types).not_to include("review_goal_retry")
          expect(trigger_types).not_to include("escalate_to_owner")
          expect(pending_trigger[:details]).to eq("No paid_agent review found for PR")
        end
      end
    end

    context "when a restarted PR has a stale successful review from before the reset" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          review_goal_retry_reset_at: 1.hour.ago)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 5, max_review_goal_retries: 3)

        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "review", status: "completed",
          created_at: 2.hours.ago,
          started_at: 90.minutes.ago,
          completed_at: 30.minutes.ago)
        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          created_at: 50.minutes.ago,
          started_at: 50.minutes.ago,
          completed_at: 50.minutes.ago)

        stub_github_for_pr(draft: true, reviews: [])
      end

      it "does not let the stale success clear current-cycle retry failures" do
        result = activity.execute(project_id: project.id)

        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |entry| entry[:type] }
        pending_trigger = trigger[:triggers].find { |entry| entry[:type] == "paid_agent_review_pending" }

        expect(trigger[:phase]).to eq("restarted")
        expect(trigger_types).to include("review_goal_retry")
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("escalate_to_owner")
        expect(pending_trigger[:details]).to match(/Retrying unsuccessful review-goal run/)
      end
    end

    context "when a restarted PR has a stale create_pr run that finishes after the reset" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          review_goal_retry_reset_at: 1.hour.ago)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 5)

        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "create_pr", status: "completed",
          created_at: 2.hours.ago,
          started_at: 90.minutes.ago,
          completed_at: 10.minutes.ago)
        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "create_pr", status: "completed",
          created_at: 55.minutes.ago,
          started_at: 55.minutes.ago,
          completed_at: 55.minutes.ago)
        create(:agent_run, :automatic,
          project: project, issue: pr_issue,
          source_pull_request_number: 42,
          goal: "review", status: "completed",
          created_at: 50.minutes.ago,
          started_at: 50.minutes.ago,
          completed_at: 50.minutes.ago)

        stub_github_for_pr(draft: true, reviews: [])
      end

      it "does not let the stale create_pr completion re-open paid_agent review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |entry| entry[:type] }

        expect(trigger[:phase]).to eq("restarted")
        expect(trigger_types).to include("ready_for_owner")
        expect(trigger_types).not_to include("paid_agent_review_pending")
      end
    end

    context "when an escalated PR exhausted paid_agent review rounds before draft restart" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
          pr_review_phase: "escalated",
          draft_review_count: 10,
          pr_followup_count: 3)
      end

      before do
        enable_paid_agent_review!(project, max_review_rounds: 3)
        3.times do
          create(:agent_run,
            project: project, issue: pr_issue,
            source_pull_request_number: 42,
            goal: "review", status: "failed",
            started_at: 1.hour.ago, completed_at: 1.hour.ago)
        end
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "re-emits paid_agent_review_pending for the restarted draft cycle" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("escalate_to_owner")
      end
    end

    context "when a draft PR is still draft on GitHub" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 3)
      end

      before do
        stub_github_for_pr(draft: true,
          checks: [ { name: "rspec", conclusion: "failure" } ])
      end

      it "does not reset counts (already in draft phase)" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.draft_review_count).to eq(3)
      end
    end

    context "when an escalated PR is not draft on GitHub" do
      let!(:pr_issue) do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
          pr_review_phase: "escalated",
          draft_review_count: 10,
          pr_followup_count: 3)
      end

      before do
        stub_github_for_pr(draft: false,
          checks: [ { name: "rspec", conclusion: "failure" } ])
      end

      it "does not restart the phase" do
        activity.execute(project_id: project.id)

        expect(pr_issue.reload.pr_review_phase).to eq("escalated")
      end

      it "does not reset counts" do
        activity.execute(project_id: project.id)

        pr_issue.reload
        expect(pr_issue.draft_review_count).to eq(10)
        expect(pr_issue.pr_followup_count).to eq(3)
      end
    end

    context "when owner has approved an escalated PR with auto_merge enabled" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
          pr_review_phase: "escalated",
          paid_state: "completed")
        stub_github_for_pr(
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )
      end

      it "returns owner_approved trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end

      it "returns owner_approved when the repo has no checks" do
        stub_github_for_pr(
          checks: [],
          reviews: default_clean_copilot_review + [
            { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("owner_approved")
      end

      it "does not emit owner_approved when auto_merge is disabled" do
        project.update!(auto_merge_mode: "off")

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when escalated PR no longer has the paid-escalated label" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "escalated",
          paid_state: "completed")
        stub_github_for_pr
      end

      it "returns dismiss_escalation trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("dismiss_escalation")
        expect(trigger[:phase]).to eq("escalated")
        expect(trigger[:draft]).to be(false)
      end
    end

    context "when a restarted PR has signals" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          draft_review_count: 2)
        stub_github_for_pr(
          draft: true,
          reviews: [ { id: 1, user_login: "copilot", state: "COMMENTED",
                     body: "I found issues.", submitted_at: 1.hour.ago } ],
          review_threads: [
            {
              id: "thread_1",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 10, author: "copilot" } ]
            }
          ]
        )
      end

      it "scans as a draft phase PR" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("restarted")
        expect(trigger[:triggers].map { |t| t[:type] }).to include("review_bot_threads")
        expect(trigger[:current_draft_review_count]).to eq(2)
      end
    end

    context "with structured logging" do
      before do
        FeatureFlags.disable!(:explicit_pr_automation_decisions, project:)
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
        stub_github_for_pr
        allow(Rails.logger).to receive(:info)
      end

      it "logs scan results" do
        activity.execute(project_id: project.id)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "pr_scanner.scan_complete",
            project_id: project.id,
            prs_scanned: 1,
            prs_skipped_unchanged: 0,
            prs_triggered: 0
          )
        )
      end

      it "logs legacy trigger totals when explicit decisions are disabled" do
        allow(Rails.logger).to receive(:info)
        allow(activity).to receive(:scan_pr).and_return({ pr_number: 42, triggers: [ { type: "ci_failure" } ] })

        activity.execute(project_id: project.id)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "pr_scanner.scan_complete",
            project_id: project.id,
            prs_scanned: 1,
            prs_skipped_unchanged: 0,
            prs_triggered: 1
          )
        )
      end
    end

    context "when skipping unchanged PRs" do
      let!(:unchanged_pr) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed",
          github_updated_at: 5.minutes.ago,
          last_pr_scan_at: 30.seconds.ago)
      end

      it "skips PRs where github_updated_at < last_pr_scan_at" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "scans PRs that have never been scanned" do
        unchanged_pr.update_column(:last_pr_scan_at, nil)
        stub_github_for_pr
        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be_present
      end

      it "scans PRs where github_updated_at >= last_pr_scan_at" do
        unchanged_pr.update_columns(
          github_updated_at: 30.minutes.ago,
          last_pr_scan_at: 1.hour.ago
        )
        stub_github_for_pr
        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be > 1.minute.ago
      end

      it "scans PRs with a recently completed agent run" do
        create(:agent_run, :completed,
          project: project,
          source_pull_request_number: 42,
          completed_at: 30.seconds.ago)
        stub_github_for_pr
        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be > 10.seconds.ago
      end

      it "rescans draft PRs whose last scan exceeds the staleness ceiling" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        unchanged_pr.update!(pr_review_phase: "draft")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )
        stub_github_for_pr

        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be > 10.seconds.ago
      end

      it "does not bypass skip for stale ready PRs authored by humans (preserves merge-conflict rescan path)" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        unchanged_pr.update!(pr_review_phase: "ready")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(unchanged_pr.reload.last_pr_scan_at).to be < ceiling.seconds.ago
      end

      it "rescans stale bot-authored ready PRs when Dependabot auto-merge is enabled" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        project.update!(auto_merge_mode: "dependabot_only")
        unchanged_pr.update!(pr_review_phase: "ready", github_creator_login: "dependabot[bot]")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )
        stub_github_for_pr(author_login: "dependabot[bot]")

        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be > 10.seconds.ago
      end

      it "does not rescan stale bot-authored ready PRs when Dependabot auto-merge is off" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        project.update!(auto_merge_mode: "off")
        unchanged_pr.update!(pr_review_phase: "ready", github_creator_login: "dependabot[bot]")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(unchanged_pr.reload.last_pr_scan_at).to be < ceiling.seconds.ago
      end

      it "rescans stale human-authored ready PRs when auto-merge mode is all" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        project.update!(auto_merge_mode: "all")
        unchanged_pr.update!(pr_review_phase: "ready")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )
        stub_github_for_pr

        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be > 10.seconds.ago
      end

      it "rescans stale human-authored escalated PRs when auto-merge mode is all" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        project.update!(auto_merge_mode: "all")
        unchanged_pr.update!(pr_review_phase: "escalated")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )
        stub_github_for_pr

        activity.execute(project_id: project.id)

        expect(unchanged_pr.reload.last_pr_scan_at).to be > 10.seconds.ago
      end

      it "does not rescan stale human-authored ready PRs when auto-merge is dependabot_only" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        project.update!(auto_merge_mode: "dependabot_only")
        unchanged_pr.update!(pr_review_phase: "ready")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(unchanged_pr.reload.last_pr_scan_at).to be < ceiling.seconds.ago
      end

      it "does not rescan stale human-authored ready PRs when auto-merge is off" do
        ceiling = described_class::SCAN_STALENESS_MULTIPLIER * project.poll_interval_seconds
        project.update!(auto_merge_mode: "off")
        unchanged_pr.update!(pr_review_phase: "ready")
        unchanged_pr.update_columns(
          github_updated_at: (ceiling + 60).seconds.ago,
          last_pr_scan_at: (ceiling + 30).seconds.ago
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
        expect(unchanged_pr.reload.last_pr_scan_at).to be < ceiling.seconds.ago
      end

      it "scans ready PRs for merge conflicts when auto-fix is enabled" do
        project.update!(auto_fix_merge_conflicts: true)
        unchanged_pr.update!(pr_review_phase: "ready")
        stub_github_for_pr(mergeable: false)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to contain_exactly(
          hash_including(
            pr_number: 42,
            phase: "ready",
            triggers: include(hash_including(type: "merge_conflicts"))
          )
        )
      end

      it "scans escalated PRs for merge conflicts when auto-fix is enabled" do
        project.update!(auto_fix_merge_conflicts: true)
        unchanged_pr.update!(pr_review_phase: "escalated")
        stub_github_for_pr(mergeable: false)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to contain_exactly(
          hash_including(
            pr_number: 42,
            phase: "escalated",
            triggers: include(hash_including(type: "merge_conflicts"))
          )
        )
      end

      it "still skips draft PRs when auto-fix is enabled" do
        project.update!(auto_fix_merge_conflicts: true)
        unchanged_pr.update!(pr_review_phase: "draft")

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "still skips ready PRs when auto-fix is disabled" do
        unchanged_pr.update!(pr_review_phase: "ready")

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "still skips ready PRs at the follow-up limit when auto-fix is enabled" do
        project.update!(auto_fix_merge_conflicts: true, max_pr_followup_runs: 1)
        unchanged_pr.update!(pr_review_phase: "ready", pr_followup_count: 1)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "does not re-emit non-conflict triggers during merge-conflict rescan" do
        project.update!(auto_fix_merge_conflicts: true)
        unchanged_pr.update!(pr_review_phase: "ready")
        stub_github_for_pr(
          mergeable: false,
          checks: [ { name: "ci", conclusion: "failure" } ],
          reviews: [ { id: 200, user_login: "reviewer", state: "CHANGES_REQUESTED",
                     body: nil, submitted_at: 1.hour.ago } ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to contain_exactly(
          hash_including(
            pr_number: 42,
            triggers: contain_exactly(hash_including(type: "merge_conflicts"))
          )
        )
      end

      it "skips unchanged ready PRs with no merge conflict when auto-fix is enabled" do
        project.update!(auto_fix_merge_conflicts: true)
        unchanged_pr.update!(pr_review_phase: "ready")
        stub_github_for_pr(mergeable: true)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "updates last_pr_scan_at after scanning" do
        unchanged_pr.update_columns(last_pr_scan_at: nil, github_updated_at: Time.current)
        stub_github_for_pr

        expect {
          activity.execute(project_id: project.id)
        }.to change { unchanged_pr.reload.last_pr_scan_at }.from(nil)
      end

      it "updates last_pr_scan_at even when triggers are emitted" do
        unchanged_pr.update_columns(last_pr_scan_at: nil, github_updated_at: Time.current)
        stub_github_for_pr(checks: [ { name: "ci", conclusion: "failure" } ])

        expect {
          activity.execute(project_id: project.id)
        }.to change { unchanged_pr.reload.last_pr_scan_at }.from(nil)
      end

      it "does not update last_pr_scan_at when an active run exists" do
        unchanged_pr.update_columns(last_pr_scan_at: nil, github_updated_at: Time.current)
        create(:agent_run,
          project: project,
          source_pull_request_number: 42,
          status: "running")

        expect {
          activity.execute(project_id: project.id)
        }.not_to change { unchanged_pr.reload.last_pr_scan_at }
      end

      it "does not update last_pr_scan_at when API fails" do
        unchanged_pr.update_columns(last_pr_scan_at: nil, github_updated_at: Time.current)
        allow(github_client).to receive(:pull_request)
          .and_raise(GithubClient::Error.new("API error"))
        allow(github_client).to receive(:review_threads)
          .with(project.full_name, 42)
          .and_return([])
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_return([])

        expect {
          activity.execute(project_id: project.id)
        }.not_to change { unchanged_pr.reload.last_pr_scan_at }
      end

      it "does not update last_pr_scan_at when reviews fail in ready phase" do
        unchanged_pr.update_columns(
          last_pr_scan_at: nil,
          github_updated_at: Time.current,
          pr_review_phase: "ready"
        )
        stub_github_for_pr
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error.new("API error"))

        expect {
          activity.execute(project_id: project.id)
        }.not_to change { unchanged_pr.reload.last_pr_scan_at }
      end

      it "still emits CI failure triggers when reviews fail in ready phase" do
        unchanged_pr.update_columns(
          last_pr_scan_at: nil,
          github_updated_at: Time.current,
          pr_review_phase: "ready"
        )
        stub_github_for_pr(checks: [ { name: "ci", conclusion: "failure" } ])
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error.new("API error"))

        result = activity.execute(project_id: project.id)
        triggers = result[:prs_to_trigger].first&.dig(:triggers) || []

        expect(triggers).to include(hash_including(type: "ci_failure"))
      end

      it "returns :skipped when partial_failure and no triggers in ready phase" do
        unchanged_pr.update_columns(
          last_pr_scan_at: nil,
          github_updated_at: Time.current,
          pr_review_phase: "ready"
        )
        stub_github_for_pr(checks: [ { name: "ci", conclusion: "success" } ])
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error.new("API error"))

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
        expect(unchanged_pr.reload.last_pr_scan_at).to be_nil
      end

      it "returns :skipped when check-run fetch fails in ready phase" do
        unchanged_pr.update_columns(
          last_pr_scan_at: nil,
          github_updated_at: Time.current,
          pr_review_phase: "ready"
        )
        stub_github_for_pr(checks: [ { name: "ci", conclusion: "success" } ])
        allow(github_client).to receive(:check_runs_for_ref)
          .and_raise(GithubClient::Error.new("API error"))

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
        expect(unchanged_pr.reload.last_pr_scan_at).to be_nil
      end

      it "returns :skipped when check-run fetch fails for a ci_action gate in ready phase" do
        unchanged_pr.update_columns(
          last_pr_scan_at: nil,
          github_updated_at: Time.current,
          pr_review_phase: "ready"
        )
        project.update!(
          review_settings: {
            "enabled" => true,
            "methods" => { "ci_action" => { "enabled" => true, "action_name" => "e2e-suite" } }
          }
        )
        stub_github_for_pr(checks: [ { name: "e2e-suite", conclusion: "success" } ])
        allow(github_client).to receive(:check_runs_for_ref)
          .and_raise(GithubClient::Error.new("API error"))

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
        expect(unchanged_pr.reload.last_pr_scan_at).to be_nil
      end

      it "reports skipped count in log output" do
        allow(Rails.logger).to receive(:info)
        allow(Rails.logger).to receive(:debug)

        activity.execute(project_id: project.id)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "pr_scanner.scan_complete",
            prs_found: 1,
            prs_scanned: 0,
            prs_skipped_unchanged: 1
          )
        )
      end
    end

    context "when a review-goal run has failed and paid_agent is enabled" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed",
          pr_review_phase: "draft")
      end

      before do
        enable_paid_agent_review!
        pr_issue
        stub_github_for_pr(draft: true, reviews: [])
      end

      it "emits review_goal_retry when most recent review-goal run failed" do
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("review_goal_retry")
        expect(trigger[:current_review_goal_retry_count]).to eq(pr_issue.review_goal_retry_count)
      end

      it "does not emit review_goal_retry when most recent review-goal run completed" do
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42,
          created_at: 2.hours.ago)
        create(:agent_run, :completed,
          project: project,
          goal: "review",
          source_pull_request_number: 42,
          created_at: 1.hour.ago)

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "does not emit review_goal_retry when paid_agent is not enabled" do
        project.update!(review_settings: { "enabled" => true, "methods" => { "copilot" => { "enabled" => true } } })
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "does not emit review_goal_retry when reviews are globally disabled" do
        project.update!(review_settings: { "enabled" => false, "methods" => { "paid_agent" => { "enabled" => true } } })
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "does not emit review_goal_retry when a manual review-goal run is still queued" do
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42,
          trigger_type: "automatic")
        create(:agent_run,
          project: project,
          goal: "review",
          status: "queued",
          trigger_type: "manual",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
        expect(triggered_types).to include("paid_agent_review_pending")
      end

      it "escalates when retry limit is reached" do
        pr_issue.update!(review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("Review-goal retry limit reached")
      end

      it "does not escalate when an automatic review-goal run is still queued" do
        pr_issue.update!(review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end
        create(:agent_run, :automatic,
          project: project,
          goal: "review",
          status: "queued",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("escalate_to_owner")
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "does not re-escalate when issue is already escalated" do
        pr_issue.update!(
          review_goal_retry_count: 3,
          pr_review_phase: "escalated",
          labels: pr_issue.labels + [ "paid-escalated" ]
        )
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("escalate_to_owner")
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "detects draft conversion before escalating at retry limit in ready phase" do
        pr_issue.update!(pr_review_phase: "ready", review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end

        stub_github_for_pr(draft: true, reviews: [])

        activity.execute(project_id: project.id)

        pr_issue.reload
        expect(pr_issue.pr_review_phase).to eq("restarted")
        expect(pr_issue.review_goal_retry_count).to eq(0)
      end

      it "escalates at retry limit in ready phase when PR is not draft" do
        pr_issue.update!(pr_review_phase: "ready", review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end
        stub_github_for_pr(draft: false, reviews: [])

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:triggers].first[:details]).to include("Review-goal retry limit reached")
      end

      it "does not escalate in ready phase while an automatic review-goal run is still running" do
        pr_issue.update!(pr_review_phase: "ready", review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end
        create(:agent_run, :automatic,
          project: project,
          goal: "review",
          status: "running",
          source_pull_request_number: 42)
        stub_github_for_pr(draft: false, reviews: [])

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("escalate_to_owner")
        expect(triggered_types).not_to include("review_goal_retry")
        expect(pr_issue.reload.pr_review_phase).to eq("ready")
      end

      it "does not escalate in ready phase while a manual review-goal run is still running" do
        pr_issue.update!(pr_review_phase: "ready", review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed, project: project, goal: "review",
            source_pull_request_number: 42, trigger_type: "automatic")
        end
        create(:agent_run, project: project, goal: "review",
          status: "running", trigger_type: "manual", source_pull_request_number: 42)
        stub_github_for_pr(draft: false, reviews: [])

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("escalate_to_owner")
        expect(triggered_types).not_to include("review_goal_retry")
        expect(triggered_types).to include("paid_agent_review_pending")
        expect(pr_issue.reload.pr_review_phase).to eq("ready")
      end

      it "skips escalation when pr_data fetch fails in ready phase at retry limit" do
        pr_issue.update!(pr_review_phase: "ready", review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end

        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "transient API error")

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
      end

      it "does not emit review_goal_retry when pr_data fetch fails in ready phase" do
        pr_issue.update!(pr_review_phase: "ready")
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "transient API error")

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to be_empty
      end

      it "resets review_goal_retry_count when PR is converted back to draft" do
        pr_issue.update!(pr_review_phase: "ready", review_goal_retry_count: 3)

        stub_github_for_pr(draft: true, reviews: [])

        activity.execute(project_id: project.id)

        expect(pr_issue.reload.review_goal_retry_count).to eq(0)
        expect(pr_issue.reload.pr_review_phase).to eq("restarted")
      end

      it "does not emit review_goal_retry when no review-goal runs exist" do
        create(:agent_run, :failed,
          project: project,
          goal: "create_pr",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "continues scanning other signals alongside review_goal_retry but the review-pending gate suppresses ci_failure" do
        stub_github_for_pr(
          draft: true,
          reviews: [],
          checks: [ { name: "rspec", conclusion: "failure" } ]
        )
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        trigger_types = trigger[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_goal_retry")
        # paid_agent_review_pending is the gate: ci_failure will be re-emitted
        # on the next scan after the review run completes.
        expect(trigger_types).not_to include("ci_failure")
      end

      it "does not emit review_goal_retry when the failed run already posted a review" do
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42,
          review_posted_at: 5.minutes.ago,
          review_url: "https://github.com/example/repo/pull/42#pullrequestreview-1")

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "does not emit review_goal_retry when the no_output run already posted a review" do
        create(:agent_run, :no_output,
          project: project,
          goal: "review",
          source_pull_request_number: 42,
          review_posted_at: 5.minutes.ago,
          review_url: "https://github.com/example/repo/pull/42#pullrequestreview-1")

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("review_goal_retry")
      end

      it "does not escalate at retry limit when paid_agent is not the sole review method" do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "copilot" => { "enabled" => true }
          }
        })
        pr_issue.update!(review_goal_retry_count: 3)
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end

        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("escalate_to_owner")
        expect(triggered_types).not_to include("review_goal_retry")
        expect(triggered_types).not_to include("paid_agent_review_pending")
      end

      it "preserves paid_agent_review_pending draft gate when sole reviewer and retry is needed" do
        stub_github_for_pr(draft: true, reviews: [])
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_goal_retry")
        expect(trigger_types).to include("paid_agent_review_pending")
        expect(trigger_types).not_to include("ready_for_owner")
      end

      it "suppresses paid_agent_review_pending when not sole reviewer and retry is needed" do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "copilot" => { "enabled" => true }
          }
        })
        stub_github_for_pr(draft: true, reviews: [])
        create(:agent_run, :failed,
          project: project,
          goal: "review",
          source_pull_request_number: 42)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
        expect(trigger_types).to include("review_goal_retry")
        expect(trigger_types).not_to include("paid_agent_review_pending")
      end
    end

    context "when a review-goal run has failed and paid_agent is a sidecar alongside copilot" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed",
          pr_review_phase: "ready",
          review_goal_retry_count: 3)
      end

      before do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "copilot" => { "enabled" => true }
          }
        })
        pr_issue
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end
        stub_github_for_pr(
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                     body: "Copilot reviewed 5 out of 5 changed files and generated no comments.",
                     submitted_at: 1.hour.ago } ],
          checks: [ { name: "rspec", conclusion: "failure" } ]
        )
      end

      it "does not escalate at retry limit and still evaluates CI signals" do
        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).not_to include("escalate_to_owner")
        expect(triggered_types).to include("ci_failure")
        expect(triggered_types).not_to include("paid_agent_review_pending")
      end
    end

    context "when a review-goal run has failed and paid_agent is a sidecar alongside manual review" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed",
          pr_review_phase: "ready",
          review_goal_retry_count: 3)
      end

      before do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "manual" => { "enabled" => true, "reviewer_login" => "alice" }
          }
        })
        pr_issue
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end
        stub_github_for_pr(reviews: [], checks: [ { name: "rspec", conclusion: "success" } ])
      end

      it "escalates at retry limit because manual review cannot recover paid_agent" do
        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).to include("escalate_to_owner")
      end
    end

    context "when a review-goal run has failed and paid_agent is a sidecar alongside ci_action" do
      let(:pr_issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          paid_state: "completed",
          pr_review_phase: "ready",
          review_goal_retry_count: 3)
      end

      before do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true },
            "ci_action" => { "enabled" => true, "action_name" => "e2e-suite" }
          }
        })
        pr_issue
        3.times do
          create(:agent_run, :failed,
            project: project,
            goal: "review",
            source_pull_request_number: 42)
        end
        stub_github_for_pr(reviews: [], checks: [ { name: "rspec", conclusion: "success" } ])
      end

      it "escalates at retry limit because ci_action cannot recover paid_agent" do
        result = activity.execute(project_id: project.id)

        triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(triggered_types).to include("escalate_to_owner")
      end
    end
  end

  context "when paid_agent is the only review method and no review-goal run exists" do
    before do
      enable_paid_agent_review!
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "blocks draft exit with a paid_agent_review_pending trigger (no ready_for_owner)" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("ready_for_owner")
    end
  end

  context "when reviews are globally disabled but paid_agent sub-flag is true" do
    let!(:disabled_reviews_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      project.update!(review_settings: {
        "enabled" => false,
        "methods" => { "paid_agent" => { "enabled" => true } }
      })
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "does not emit a paid_agent_review_pending trigger" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("paid_agent_review_pending")
    end

    it "does not escalate based on historical failed review-goal runs" do
      create(:agent_run, :failed,
        project: project, issue: disabled_reviews_issue,
        source_pull_request_number: 42,
        goal: "review")

      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("escalate_to_owner")
    end
  end

  context "when paid_agent is enabled and a review-goal run is already queued" do
    before do
      enable_paid_agent_review!
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "queued")
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "keeps the paid_agent_review_pending trigger active" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      pending_trigger = trigger[:triggers].find { |t| t[:type] == "paid_agent_review_pending" }

      expect(pending_trigger).to be_present
      expect(pending_trigger[:active_run]).to be(true)
      expect(pending_trigger[:details]).to eq("paid_agent review run is still in progress")
      expect(trigger[:triggers].map { |t| t[:type] }).not_to include("ready_for_owner")
    end
  end

  context "when paid_agent is the only review method and a review-goal run is already running" do
    before do
      enable_paid_agent_review!
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "running")
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "still blocks draft exit until the review is posted" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }

      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("ready_for_owner")
    end
  end

  context "when paid_agent is enabled and max_review_rounds is reached" do
    before do
      enable_paid_agent_review!(project, max_review_rounds: 2)
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      2.times do
        create(:agent_run,
          project: project, issue: issue,
          source_pull_request_number: 42,
          goal: "review", status: "completed",
          completed_at: 1.hour.ago)
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "does not emit a paid_agent_review_pending trigger" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent is enabled and the last review is newer than the last create_pr run" do
    before do
      enable_paid_agent_review!
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 2.hours.ago)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "completed",
        completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "does not emit a paid_agent_review_pending trigger" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent is enabled and the last review run timed out (no new code since)" do
    before do
      enable_paid_agent_review!
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 2.hours.ago)
      run = create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "timeout")
      run.update_columns(updated_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "retries the timed-out review" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).to include("review_goal_retry")
      expect(triggers).to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent is enabled and timed-out review runs hit max_review_rounds" do
    before do
      enable_paid_agent_review!(project, max_review_rounds: 2)
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      2.times do
        create(:agent_run,
          project: project, issue: issue,
          source_pull_request_number: 42,
          goal: "review", status: "timeout")
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "does not emit a paid_agent_review_pending trigger" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent review retries are present" do
    before do
      enable_paid_agent_review!(project, max_review_rounds: 2)
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 3.hours.ago)
      retried_run = create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "retried")
      retried_run.update_columns(updated_at: 2.hours.ago)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "completed",
        completed_at: 90.minutes.ago)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "emits a paid_agent_review_pending trigger because retried runs do not consume review rounds" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      expect(trigger[:triggers].map { |t| t[:type] }).to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent is enabled and the last create_pr run is newer than the last review" do
    before do
      enable_paid_agent_review!
      issue = create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "review", status: "completed",
        completed_at: 2.hours.ago)
      create(:agent_run,
        project: project, issue: issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "emits a paid_agent_review_pending trigger" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      expect(trigger[:triggers].map { |t| t[:type] }).to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent is enabled and a review-goal run has failed" do
    let(:failed_review_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!
      create(:agent_run,
        project: project, issue: failed_review_issue,
        source_pull_request_number: 42,
        goal: "review", status: "failed",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "emits a paid_agent_review_pending trigger to retry" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      details = trigger[:triggers].find { |t| t[:type] == "paid_agent_review_pending" }[:details]
      expect(details).to match(/Retrying unsuccessful review-goal run/)
    end

    it "does not wedge the PR — trigger is emitted on every scan cycle" do
      result1 = activity.execute(project_id: project.id)
      failed_review_issue.update_column(:last_pr_scan_at, nil)
      result2 = activity.execute(project_id: project.id)

      expect(result1[:prs_to_trigger].size).to eq(1)
      expect(result2[:prs_to_trigger].size).to eq(1)
    end

    it "does not retry when the failed run already posted a review" do
      run = project.agent_runs.where(goal: "review", source_pull_request_number: 42).first
      run.update!(review_posted_at: 5.minutes.ago, review_url: "https://github.com/example/repo/pull/42#pullrequestreview-1")

      result = activity.execute(project_id: project.id)

      triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
      expect(triggered_types).not_to include("paid_agent_review_pending")
    end

    it "re-triggers review when a newer create_pr run exists after a posted-but-failed review" do
      run = project.agent_runs.where(goal: "review", source_pull_request_number: 42).first
      run.update!(review_posted_at: 30.minutes.ago, review_url: "https://github.com/example/repo/pull/42#pullrequestreview-1")

      create(:agent_run,
        project: project, issue: failed_review_issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        trigger_type: "automatic",
        started_at: 10.minutes.ago, completed_at: 10.minutes.ago)

      result = activity.execute(project_id: project.id)

      triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
      expect(triggered_types).to include("paid_agent_review_pending")
    end
  end

  context "when a failed automatic paid_agent review-goal run is followed by a cancelled automatic run" do
    let(:cancelled_review_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!
      create(:agent_run,
        project: project, issue: cancelled_review_issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        trigger_type: "automatic",
        started_at: 3.hours.ago, completed_at: 3.hours.ago)
      create(:agent_run,
        project: project, issue: cancelled_review_issue,
        source_pull_request_number: 42,
        goal: "review", status: "failed",
        trigger_type: "automatic",
        started_at: 2.hours.ago, completed_at: 2.hours.ago)
      create(:agent_run,
        project: project, issue: cancelled_review_issue,
        source_pull_request_number: 42,
        goal: "review", status: "cancelled",
        trigger_type: "automatic",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "does not emit review_goal_retry or paid_agent_review_pending" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("review_goal_retry")
      expect(triggers).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent review-goal retry limit is reached" do
    let(:retry_limit_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(project, max_review_rounds: 3)
      3.times do
        create(:agent_run,
          project: project, issue: retry_limit_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "escalates to owner instead of retrying" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("escalate_to_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
      details = trigger[:triggers].find { |t| t[:type] == "escalate_to_owner" }[:details]
      expect(details).to match(/Review-goal retry limit reached/)
    end

    it "includes owner_reviewer_login for escalation handling" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      expect(trigger).to have_key(:owner_reviewer_login)
    end

    it "does not count manual review runs toward the retry breaker" do
      enable_paid_agent_review!(project, max_review_rounds: 5)
      retry_limit_issue.agent_runs.destroy_all
      2.times do
        create(:agent_run,
          project: project, issue: retry_limit_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed", trigger_type: "automatic",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      create(:agent_run,
        project: project, issue: retry_limit_issue,
        source_pull_request_number: 42,
        goal: "review", status: "failed", trigger_type: "manual",
        started_at: 30.minutes.ago, completed_at: 30.minutes.ago)

      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end

    it "lets a manual clean review reset the automatic retry breaker" do
      enable_paid_agent_review!(project, max_review_rounds: 5)
      retry_limit_issue.agent_runs.destroy_all
      [ 3.hours.ago, 2.hours.ago ].each do |timestamp|
        create(:agent_run, project: project, issue: retry_limit_issue, source_pull_request_number: 42,
          goal: "review", status: "failed", trigger_type: "automatic",
          started_at: timestamp, completed_at: timestamp)
      end
      create(:agent_run, project: project, issue: retry_limit_issue, source_pull_request_number: 42,
        goal: "review", status: "completed", trigger_type: "manual",
        started_at: 90.minutes.ago, completed_at: 90.minutes.ago)
      create(:agent_run, project: project, issue: retry_limit_issue, source_pull_request_number: 42,
        goal: "review", status: "failed", trigger_type: "automatic",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)

      result = activity.execute(project_id: project.id)

      trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end

    it "does not count manual review runs toward paid_agent max_review_rounds" do
      enable_paid_agent_review!(project, max_review_rounds: 1)
      retry_limit_issue.agent_runs.destroy_all
      create(:agent_run,
        project: project, issue: retry_limit_issue,
        source_pull_request_number: 42,
        goal: "review", status: "completed", trigger_type: "manual",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)

      result = activity.execute(project_id: project.id)

      trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end

    it "does not let a manual review suppress paid_agent retries after create_pr" do
      enable_paid_agent_review!(project, max_review_rounds: 5)
      retry_limit_issue.agent_runs.destroy_all
      create(:agent_run,
        project: project, issue: retry_limit_issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 2.hours.ago)
      create(:agent_run,
        project: project, issue: retry_limit_issue,
        source_pull_request_number: 42,
        goal: "review", status: "completed", trigger_type: "manual",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)

      result = activity.execute(project_id: project.id)

      trigger_types = result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end
  end

  context "when max_review_rounds is lower than default MAX_REVIEW_GOAL_RETRIES" do
    let(:low_rounds_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(project, max_review_rounds: 1)
      create(:agent_run,
        project: project, issue: low_rounds_issue,
        source_pull_request_number: 42,
        goal: "review", status: "failed",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "caps default retry limit to max_review_rounds and escalates" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("escalate_to_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
    end
  end

  context "when a ready PR at review-goal retry limit is NOT converted back to draft" do
    let(:ready_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "ready",
        pr_followup_count: 0)
    end

    before do
      enable_paid_agent_review!(project)
      3.times do
        create(:agent_run,
          project: project, issue: ready_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr
    end

    it "escalates to owner because the PR is still ready (not draft)" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
    end
  end

  context "when a ready PR at review-goal retry limit is already owner-approved" do
    let(:approved_ready_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "ready",
        paid_state: "completed")
    end

    before do
      enable_paid_agent_review!(project)
      project.update!(owner_reviewer_login: "viamin", auto_merge_mode: "all")
      3.times do
        create(:agent_run,
          project: project, issue: approved_ready_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(
        reviews: [
          { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
           body: "Review complete.\n<!-- paid-review-clean -->", submitted_at: 2.hours.ago },
          { id: 2, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
        ]
      )
    end

    it "returns owner_approved instead of escalating" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("owner_approved")
      expect(trigger_types).not_to include("escalate_to_owner")
    end
  end

  context "when a ready PR was recently dismissed from escalation" do
    let(:dismissed_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "ready",
        pr_followup_count: 0,
        review_goal_retry_reset_at: Time.current)
    end

    before do
      enable_paid_agent_review!(project)
      3.times do
        create(:agent_run,
          project: project, issue: dismissed_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(reviews: [])
    end

    it "does not immediately re-escalate on the next scan" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger]).to be_empty
      expect(dismissed_retry_issue.reload.pr_review_phase).to eq("ready")
    end
  end

  context "when a ready PR at retry limit has a transient fetch_pr_data failure" do
    let(:fetch_fail_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "ready",
        pr_followup_count: 0)
    end

    before do
      enable_paid_agent_review!(project)
      3.times do
        create(:agent_run,
          project: project, issue: fetch_fail_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      allow(github_client).to receive(:pull_request)
        .with(project.full_name, 42)
        .and_raise(GithubClient::Error, "transient API failure")
    end

    it "returns :skipped instead of escalating on stale data" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger]).to be_empty
      expect(fetch_fail_issue.reload.pr_review_phase).to eq("ready")
    end
  end

  context "when a newer create_pr cycle follows historical review-goal failures" do
    let(:new_cycle_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(project, max_review_rounds: 5, max_review_goal_retries: 2)
      2.times do |index|
        create(:agent_run, :failed,
          project: project, issue: new_cycle_issue,
          source_pull_request_number: 42,
          goal: "review",
          started_at: (4 - index).hours.ago,
          completed_at: (4 - index).hours.ago)
      end
      create(:agent_run, :completed,
        project: project, issue: new_cycle_issue,
        source_pull_request_number: 42,
        goal: "create_pr",
        started_at: 90.minutes.ago,
        completed_at: 90.minutes.ago)
      create(:agent_run, :failed,
        project: project, issue: new_cycle_issue,
        source_pull_request_number: 42,
        goal: "review",
        started_at: 1.hour.ago,
        completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "retries instead of escalating because the breaker resets for the new cycle" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end
  end

  context "when a successful review follows historical review-goal failures" do
    let(:successful_review_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(project, max_review_rounds: 5, max_review_goal_retries: 2)
      2.times do |index|
        create(:agent_run, :failed,
          project: project, issue: successful_review_issue,
          source_pull_request_number: 42,
          goal: "review",
          started_at: (4 - index).hours.ago,
          completed_at: (4 - index).hours.ago)
      end
      create(:agent_run, :completed,
        project: project, issue: successful_review_issue,
        source_pull_request_number: 42,
        goal: "review",
        started_at: 90.minutes.ago,
        completed_at: 90.minutes.ago)
      create(:agent_run, :failed,
        project: project, issue: successful_review_issue,
        source_pull_request_number: 42,
        goal: "review",
        started_at: 1.hour.ago,
        completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "retries instead of escalating because the breaker resets after a successful review" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end
  end

  context "when paid_agent review-goal has mixed failed and completed runs" do
    let(:mixed_runs_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(project, max_review_rounds: 3)
      create(:agent_run,
        project: project, issue: mixed_runs_issue,
        source_pull_request_number: 42,
        goal: "create_pr", status: "completed",
        completed_at: 4.hours.ago)
      create(:agent_run,
        project: project, issue: mixed_runs_issue,
        source_pull_request_number: 42,
        goal: "review", status: "failed",
        started_at: 3.hours.ago, completed_at: 3.hours.ago)
      create(:agent_run,
        project: project, issue: mixed_runs_issue,
        source_pull_request_number: 42,
        goal: "review", status: "completed",
        completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "does not retry when a completed review exists after the last create_pr run" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent review-goal retries use custom max_review_goal_retries" do
    let(:custom_retries_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      project.update!(review_settings: {
        "enabled" => true,
        "methods" => {
          "paid_agent" => {
            "enabled" => true,
            "termination" => {
              "max_review_rounds" => 3,
              "max_review_goal_retries" => 1
            }
          }
        }
      })
      create(:agent_run,
        project: project, issue: custom_retries_issue,
        source_pull_request_number: 42,
        goal: "review", status: "failed",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "escalates after custom retry limit" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("escalate_to_owner")
    end
  end

  context "when paid_agent review-goal fails with timeout status" do
    let(:timeout_review_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!
      create(:agent_run,
        project: project, issue: timeout_review_issue,
        source_pull_request_number: 42,
        goal: "review", status: "timeout",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "counts timeout as a failure and retries" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent review-goal ends with no_output status" do
    let(:no_output_review_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!
      create(:agent_run,
        project: project, issue: no_output_review_issue,
        source_pull_request_number: 42,
        goal: "review", status: "no_output",
        started_at: 1.hour.ago, completed_at: 1.hour.ago)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "treats no_output as retryable and re-emits paid_agent_review_pending" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("paid_agent_review_pending")
      expect(trigger_types).not_to include("escalate_to_owner")
    end

    it "does not re-emit paid_agent_review_pending when the no_output run already posted a review" do
      run = project.agent_runs.where(goal: "review", source_pull_request_number: 42).first
      run.update!(review_posted_at: 5.minutes.ago, review_url: "https://github.com/example/repo/pull/42#pullrequestreview-1")

      result = activity.execute(project_id: project.id)

      triggered_types = (result[:prs_to_trigger] || []).flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
      expect(triggered_types).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent review-goal reaches the retry limit with no_output runs" do
    let(:no_output_retry_limit_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(project, max_review_rounds: 3)
      3.times do
        create(:agent_run,
          project: project, issue: no_output_retry_limit_issue,
          source_pull_request_number: 42,
          goal: "review", status: "no_output",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "escalates instead of getting stuck behind the rounds cap" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("escalate_to_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent review-goal has multiple posted-but-failed runs" do
    let(:posted_failed_review_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      enable_paid_agent_review!(max_review_rounds: 3)
      3.times do |index|
        create(:agent_run,
          project: project, issue: posted_failed_review_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: (3 - index).hours.ago,
          completed_at: (3 - index).hours.ago,
          review_posted_at: (3 - index).hours.ago,
          review_url: "https://github.com/example/repo/pull/42#pullrequestreview-#{index + 1}")
      end
      stub_github_for_pr(draft: true, reviews: [
        { id: 200, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
         body: "Found issues.", submitted_at: 10.minutes.ago }
      ])
    end

    it "does not treat posted failures as exhausting the retry budget" do
      result = activity.execute(project_id: project.id)

      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("review_bot_comments")
      expect(trigger_types).not_to include("escalate_to_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
    end
  end

  context "when escalated PR has reached the review-goal retry limit and the escalation label was removed" do
    let(:escalated_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "escalated",
        paid_state: "completed")
    end

    before do
      enable_paid_agent_review!
      3.times do
        create(:agent_run,
          project: project, issue: escalated_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr
    end

    it "still dismisses instead of getting stuck behind the retry limit" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      expect(trigger[:triggers].first[:type]).to eq("dismiss_escalation")
    end

    it "does not emit escalate_to_owner for an already-escalated PR" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("escalate_to_owner")
    end
  end

  context "when escalated PR at retry limit still has the escalation label" do
    let(:escalated_no_dismiss_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
        pr_review_phase: "escalated",
        paid_state: "completed")
    end

    before do
      enable_paid_agent_review!
      3.times do
        create(:agent_run,
          project: project, issue: escalated_no_dismiss_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr
    end

    it "does not emit paid_agent_review_pending at the retry limit" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("paid_agent_review_pending")
    end

    it "does not emit escalate_to_owner for an already-escalated PR" do
      result = activity.execute(project_id: project.id)

      triggers = result[:prs_to_trigger].flat_map { |pr| pr[:triggers].map { |t| t[:type] } }
      expect(triggers).not_to include("escalate_to_owner")
    end
  end

  context "when an escalated draft PR has the escalation label removed" do
    before do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "escalated",
        paid_state: "completed")
      stub_github_for_pr(draft: true)
    end

    it "detects dismissal before the draft restart path" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger]).to contain_exactly(
        hash_including(
          pr_number: 42,
          phase: "escalated",
          draft: true,
          triggers: contain_exactly(hash_including(type: "dismiss_escalation"))
        )
      )
    end
  end

  context "when paid_agent is the only review method and a clean review exists" do
    before do
      enable_paid_agent_review!
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      stub_github_for_pr(draft: true, reviews: [
        { id: 200, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
         body: "Review complete.\n<!-- paid-review-clean -->", submitted_at: 1.hour.ago }
      ])
    end

    it "allows draft exit with ready_for_owner when paid_agent review is clean" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("ready_for_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
    end
  end

  context "when paid_agent is enabled alongside copilot with no reviews" do
    before do
      project.update!(review_settings: {
        "enabled" => true,
        "methods" => {
          "copilot" => { "enabled" => true },
          "paid_agent" => { "enabled" => true }
        }
      })
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "gates draft exit via copilot (paid_agent does not independently block)" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("review_bot_review_pending")
      expect(trigger_types).not_to include("ready_for_owner")
    end
  end

  context "when paid_agent is enabled alongside copilot and review-goal retries are exhausted" do
    let(:mixed_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      project.update!(review_settings: {
        "enabled" => true,
        "methods" => {
          "copilot" => { "enabled" => true },
          "paid_agent" => {
            "enabled" => true,
            "termination" => { "max_review_rounds" => 3 }
          }
        }
      })
      3.times do
        create(:agent_run,
          project: project, issue: mixed_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "stops retrying paid_agent and lets copilot keep gating the PR" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).not_to include("escalate_to_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
      expect(trigger_types).to include("review_bot_review_pending")
    end
  end

  context "when paid_agent is enabled alongside codex with no reviews and paid_agent rounds exhausted" do
    before do
      project.update!(
        owner_reviewer_login: "viamin",
        review_settings: {
          "enabled" => true,
          "methods" => {
            "paid_agent" => {
              "enabled" => true,
              "termination" => { "max_review_rounds" => 2 }
            },
            "codex" => { "enabled" => true }
          }
        }
      )
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 1)
      stub_github_for_pr(
        draft: true,
        reviews: [
          { id: 1, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
           body: "Found issues.", submitted_at: 2.hours.ago },
          { id: 2, user_login: "paid-code-reviewer[bot]", state: "COMMENTED",
           body: "Still has issues.", submitted_at: 1.hour.ago }
        ]
      )
    end

    it "does not escalate or retry paid_agent and lets codex continue" do
      result = activity.execute(project_id: project.id)

      trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |x| x[:type] } }
      expect(trigger_types).not_to include("escalate_to_owner")
      expect(trigger_types).not_to include("paid_agent_review_pending")
      expect(trigger_types).to include("review_bot_comments")
    end
  end

  context "when paid_agent is enabled alongside manual and review-goal retries are exhausted" do
    let(:manual_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      project.update!(review_settings: {
        "enabled" => true,
        "methods" => {
          "paid_agent" => {
            "enabled" => true,
            "termination" => { "max_review_rounds" => 5 }
          },
          "manual" => {
            "enabled" => true,
            "reviewer_login" => "project-owner"
          }
        }
      })
      3.times do
        create(:agent_run,
          project: project, issue: manual_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "escalates because paid_agent is the sole bot and manual cannot recover failed review-goal runs" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("escalate_to_owner")
    end
  end

  context "when paid_agent is enabled alongside ci_action and review-goal retries are exhausted" do
    let(:ci_retry_issue) do
      create(:issue, :pull_request,
        project: project, github_number: 42,
        labels: [ "paid-generated", "paid-automation" ],
        pr_review_phase: "draft",
        draft_review_count: 0)
    end

    before do
      project.update!(review_settings: {
        "enabled" => true,
        "methods" => {
          "paid_agent" => {
            "enabled" => true,
            "termination" => { "max_review_rounds" => 5 }
          },
          "ci_action" => {
            "enabled" => true,
            "action_name" => "ci-review"
          }
        }
      })
      3.times do
        create(:agent_run,
          project: project, issue: ci_retry_issue,
          source_pull_request_number: 42,
          goal: "review", status: "failed",
          started_at: 1.hour.ago, completed_at: 1.hour.ago)
      end
      stub_github_for_pr(draft: true, reviews: [])
    end

    it "escalates because paid_agent is the sole bot and ci_action cannot recover failed review-goal runs" do
      result = activity.execute(project_id: project.id)

      expect(result[:prs_to_trigger].size).to eq(1)
      trigger = result[:prs_to_trigger].first
      trigger_types = trigger[:triggers].map { |t| t[:type] }
      expect(trigger_types).to include("escalate_to_owner")
    end
  end

  private

  # Helper to stub GitHub API calls with sensible defaults.
  # Override specific parameters to test different signal combinations.
  def stub_github_for_pr(
    mergeable: true,
    draft: false,
    author_login: "someone-else",
    head_repo_fork: false,
    checks: [ { name: "ci", conclusion: "success" } ],
    review_threads: [],
    issue_comments: [],
    recent_issue_comments: nil,
    reviews: default_clean_copilot_review,
    recent_multi_page: false,
    head_committed_at: 2.hours.ago
  )
    pr_data = OpenStruct.new(
      head: OpenStruct.new(sha: "abc123", repo: OpenStruct.new(fork: head_repo_fork)),
      mergeable: mergeable,
      draft: draft,
      number: 42,
      user: OpenStruct.new(login: author_login)
    )

    commit_data = OpenStruct.new(
      commit: OpenStruct.new(
        committer: OpenStruct.new(date: head_committed_at)
      )
    )
    recent = recent_issue_comments || issue_comments
    multi_page = recent_multi_page
    recent.define_singleton_method(:multi_page?) { multi_page }

    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)
    allow(github_client).to receive(:check_runs_for_ref)
      .with(project.full_name, "abc123")
      .and_return(checks)
    allow(github_client).to receive(:review_threads)
      .with(project.full_name, 42)
      .and_return(review_threads)
    allow(github_client).to receive(:recent_issue_comments)
      .with(project.full_name, 42)
      .and_return(recent)
    allow(github_client).to receive(:issue_comments)
      .with(project.full_name, 42)
      .and_return(issue_comments)
    allow(github_client).to receive(:pull_request_reviews)
      .with(project.full_name, 42)
      .and_return(reviews)
    allow(github_client).to receive(:commit)
      .with(project.full_name, "abc123")
      .and_return(commit_data)
  end

  def default_clean_copilot_review
    [ { id: 100, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
      body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago } ]
  end
end
