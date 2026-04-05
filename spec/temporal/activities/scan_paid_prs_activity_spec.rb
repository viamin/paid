# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::ScanPaidPrsActivity do
  let(:activity) { described_class.new }
  let(:project) do
    create(:project,
      auto_scan_prs: true,
      max_pr_followup_runs: 3,
      pr_action_labels: [],
      auto_fix_merge_conflicts: false)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when project is missing" do
      it "returns empty result with project_missing flag" do
        result = activity.execute(project_id: -1)

        expect(result[:prs_to_trigger]).to eq([])
        expect(result[:project_missing]).to be true
      end
    end

    context "when auto_scan_prs is disabled" do
      before { project.update!(auto_scan_prs: false) }

      it "returns empty result" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
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
          issue_comments: []
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
          checks: [],
          reviews: [ { id: 1, user_login: "copilot", state: "COMMENTED",
                       body: "I found some issues.", submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "treats the review as effectively clean and does not request another review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when PR is in draft phase with Claude review threads" do
      before do
        project.update!(review_settings: {
          "enabled" => true,
          "wait_for_reviews" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true }
          }
        })
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
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
        project.update!(review_settings: {
          "enabled" => true,
          "wait_for_reviews" => true,
          "methods" => {
            "paid_agent" => { "enabled" => true }
          }
        })
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
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

    context "when review bot review body says generated no comments" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
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

      it "does not return review_bot_threads trigger when review body is clean" do
        result = activity.execute(project_id: project.id)

        trigger_types = result[:prs_to_trigger].flat_map { |t| t[:triggers].map { |tr| tr[:type] } }
        expect(trigger_types).not_to include("review_bot_threads")
      end
    end

    context "when no review bot review exists and CI is green" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(reviews: [])
      end

      it "keeps the PR in draft and requests a bot review" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:phase]).to eq("draft")
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
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
        stub_github_for_pr
        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, 42)
          .and_raise(GithubClient::Error, "GitHub review API unavailable")
      end

      it "does not advance the PR out of draft" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
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
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
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

    context "when draft PR has CI green and no Copilot threads" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
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

    context "when draft PR has some green checks but others still pending" do
      before do
        project.update!(owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
        stub_github_for_pr(
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
    end

    context "when draft review limit is reached" do
      before do
        project.update!(max_draft_review_rounds: 3, owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 3)
      end

      it "returns escalate_to_owner trigger" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("escalate_to_owner")
        expect(trigger[:current_draft_review_count]).to eq(3)
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
        stub_github_for_pr(issue_comments: [ comment ])
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
          checks: [],
          reviews: [ { id: 1, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
                       body: "Copilot reviewed 20 out of 20 changed files in this pull request and generated 3 comments.",
                       submitted_at: 1.hour.ago } ],
          review_threads: []
        )
      end

      it "treats the review as effectively clean when all threads are resolved" do
        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when max_draft_review_rounds is zero (skip draft phase)" do
      before do
        project.update!(max_draft_review_rounds: 0, owner_reviewer_login: "viamin")
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
      end

      it "still requires a clean bot review before returning ready_for_owner" do
        stub_github_for_pr(
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
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 200, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
              body: "Copilot reviewed 3 out of 5 changed files and generated 2 comments.",
              submitted_at: 1.hour.ago }
          ],
          review_threads: [
            {
              id: "thread_bot",
              is_resolved: false,
              comments: [ { body: "Fix this", path: "app/model.rb", line: 5,
                            author: "copilot-pull-request-reviewer[bot]" } ]
            }
          ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        # Should be pending (not empty) because threads were not fetched in skip mode
        expect(trigger[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "returns ready_for_owner when CI is green and the latest bot review is clean" do
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "does not return ready_for_owner when CI is pending" do
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: nil } ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end

      it "returns ready_for_owner for ci_action-only review gates when the action succeeds" do
        project.update!(review_settings: ci_action_review_settings)

        stub_github_for_pr(
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "codex-review", conclusion: "success", completed_at: Time.current }
          ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        trigger = result[:prs_to_trigger].first
        expect(trigger[:triggers].first[:type]).to eq("ready_for_owner")
      end
    end

    context "when paid_agent is the configured blocking review method" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "wait_for_reviews" => true,
            "methods" => {
              "paid_agent" => { "enabled" => true }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
      end

      it "still checks unresolved threads when draft comment signals are skipped" do
        project.update!(max_draft_review_rounds: 0)
        create(:agent_run, :completed, project: project, source_pull_request_number: 42,
          completed_at: 2.hours.ago)
        create(:agent_run, :with_review, project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago, review_posted_at: 1.hour.ago,
          review_url: "https://github.com/example/repo/pull/42#pullrequestreview-123")

        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "waits for a completed review-goal run before advancing" do
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "treats a newer completed review-goal run as satisfying the review gate" do
        create(:agent_run, :completed, project: project, source_pull_request_number: 42,
          completed_at: 2.hours.ago)
        create(:agent_run, :with_review, project: project, source_pull_request_number: 42,
          completed_at: 1.hour.ago, review_posted_at: 1.hour.ago,
          review_url: "https://github.com/example/repo/pull/42#pullrequestreview-123")

        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "keeps waiting when the latest paid review still has unresolved inline comments" do
        create_paid_review_baseline(review_url: "https://github.com/example/repo/pull/42#pullrequestreview-123")

        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: [ build_review_thread(review_url: "https://github.com/example/repo/pull/42#pullrequestreview-123") ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |trigger| trigger[:type] })
          .to eq([ "paid_agent_review_threads" ])
      end

      it "ignores unresolved threads from a different review run" do
        create_paid_review_baseline(review_url: "https://github.com/example/repo/pull/42#pullrequestreview-123")

        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: [ build_review_thread(review_url: "https://github.com/example/repo/pull/42#pullrequestreview-999",
            body: "Older unresolved thread") ]
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "keeps waiting when the latest completed review-goal run never posted a review" do
        create(:agent_run, :completed, project: project, source_pull_request_number: 42,
          completed_at: 2.hours.ago)
        create(:agent_run, :completed, project: project, source_pull_request_number: 42,
          goal: "review", completed_at: 1.hour.ago, review_posted_at: nil)

        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |trigger| trigger[:type] })
          .to eq([ "review_bot_review_pending" ])
      end
    end

    context "when manual review is the configured blocking review method" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "wait_for_reviews" => true,
            "methods" => {
              "manual" => { "enabled" => true }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
      end

      it "waits for a trusted human review before advancing" do
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "accepts a trusted human review as satisfying the gate" do
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [
            { id: 1, user_login: "viamin", state: "COMMENTED", body: "Looks good",
              submitted_at: Time.current }
          ],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ready_for_owner")
      end
    end

    context "when ci_action is the configured blocking review method" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "wait_for_reviews" => true,
            "methods" => {
              "ci_action" => { "enabled" => true, "action_name" => "codex-review" }
            }
          }
        )
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "draft",
          draft_review_count: 0)
      end

      it "waits for the named review action to complete" do
        stub_github_for_pr(
          checks: [ { name: "ci", conclusion: "success" } ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].map { |t| t[:type] }).to eq([ "review_bot_review_pending" ])
      end

      it "treats a completed named review action as satisfying the gate" do
        stub_github_for_pr(
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "codex-review", conclusion: "success", completed_at: Time.current }
          ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers].first[:type]).to eq("ready_for_owner")
      end

      it "keeps waiting when the latest named review action failed" do
        stub_github_for_pr(
          checks: [
            { name: "ci", conclusion: "success" },
            { name: "codex-review", conclusion: "failure", completed_at: Time.current }
          ],
          reviews: [],
          review_threads: []
        )

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger].size).to eq(1)
        expect(result[:prs_to_trigger].first[:triggers]).to eq([
          { type: "review_bot_review_pending",
            details: "CI review action still pending: codex-review" }
        ])
      end
    end

    # --- Ready phase scanning ---

    context "when owner has approved the PR" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_enabled: true)
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

      it "does not emit owner_approved when auto_merge is disabled" do
        project.update!(auto_merge_enabled: false)

        result = activity.execute(project_id: project.id)

        expect(result[:prs_to_trigger]).to eq([])
      end
    end

    context "when owner reviewer is also the PR author" do
      before do
        project.update!(owner_reviewer_login: "viamin", auto_merge_enabled: true)
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
        project.update!(owner_reviewer_login: "viamin", auto_merge_enabled: true)
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
          labels: [ "paid-generated", "paid-automation" ],
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
          labels: [ "paid-generated", "paid-automation" ],
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
          labels: [ "paid-generated", "paid-automation" ],
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

    context "when a restarted PR has signals" do
      before do
        create(:issue, :pull_request,
          project: project, github_number: 42,
          labels: [ "paid-generated", "paid-automation" ],
          pr_review_phase: "restarted",
          draft_review_count: 2)
        stub_github_for_pr(
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

    context "when project is configured with only manual review method" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "wait_for_reviews" => true,
            "methods" => {
              "manual" => { "enabled" => true }
            }
          }
        )
      end

      it "does not append generic review bot thread triggers for draft PRs" do
        create_paid_pr(pr_review_phase: "draft", draft_review_count: 0)

        expect(trigger_types_for_non_copilot_review_threads).not_to include("review_bot_threads")
      end

      it "does not append generic review bot thread triggers for ready PRs" do
        create_paid_pr(pr_review_phase: "ready")

        expect(trigger_types_for_non_copilot_review_threads).not_to include("review_bot_threads")
      end
    end

    context "when project is configured with only ci_action review method" do
      before do
        project.update!(review_settings: ci_action_review_settings("codex-review"))
      end

      it "does not append generic review bot thread triggers" do
        create_paid_pr(pr_review_phase: "draft", draft_review_count: 0)

        expect(trigger_types_for_non_copilot_review_threads).not_to include("review_bot_threads")
      end
    end

    context "when project is configured with paid_agent review method" do
      before do
        project.update!(
          review_settings: {
            "enabled" => true,
            "wait_for_reviews" => true,
            "methods" => {
              "paid_agent" => { "enabled" => true }
            }
          }
        )
      end

      it "does append generic review bot thread triggers" do
        create_paid_pr(pr_review_phase: "draft", draft_review_count: 0)

        expect(trigger_types_for_non_copilot_review_threads).to include("review_bot_threads")
      end
    end

    context "with structured logging" do
      before do
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
            prs_triggered: 0
          )
        )
      end
    end
  end

  private

  # Helper to stub GitHub API calls with sensible defaults.
  # Override specific parameters to test different signal combinations.
  def stub_github_for_pr(
    mergeable: true,
    draft: false,
    author_login: "someone-else",
    checks: [ { name: "ci", conclusion: "success" } ],
    review_threads: [],
    issue_comments: [],
    reviews: default_clean_copilot_review
  )
    pr_data = OpenStruct.new(
      head: OpenStruct.new(sha: "abc123"),
      mergeable: mergeable,
      draft: draft,
      user: OpenStruct.new(login: author_login)
    )

    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)
    allow(github_client).to receive(:check_runs_for_ref)
      .with(project.full_name, "abc123")
      .and_return(checks)
    allow(github_client).to receive(:review_threads)
      .with(project.full_name, 42)
      .and_return(review_threads)
    allow(github_client).to receive(:issue_comments)
      .with(project.full_name, 42)
      .and_return(issue_comments)
    allow(github_client).to receive(:pull_request_reviews)
      .with(project.full_name, 42)
      .and_return(reviews)
  end

  def default_clean_copilot_review
    [ { id: 100, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
        body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago } ]
  end

  def create_paid_pr(pr_review_phase:, draft_review_count: nil)
    attributes = {
      project: project,
      github_number: 42,
      labels: [ "paid-generated", "paid-automation" ],
      pr_review_phase: pr_review_phase
    }
    attributes[:draft_review_count] = draft_review_count unless draft_review_count.nil?

    create(:issue, :pull_request, **attributes)
  end

  def create_paid_review_baseline(review_url:)
    create(:agent_run, :completed, project: project, source_pull_request_number: 42,
      completed_at: 2.hours.ago)
    create(:agent_run, :with_review, project: project, source_pull_request_number: 42,
      completed_at: 1.hour.ago, review_posted_at: 1.hour.ago, review_url: review_url)
  end

  def build_review_thread(review_url:, body: "Please address this")
    {
      is_resolved: false,
      comments: [
        {
          author: "project-owner",
          body: body,
          review_url: review_url
        }
      ]
    }
  end

  def trigger_types_for_non_copilot_review_threads
    stub_github_for_pr(
      checks: [ { name: "ci", conclusion: "success" } ],
      reviews: [],
      review_threads: [
        {
          is_resolved: false,
          comments: [
            { author: "claude-code[bot]", body: "Some comment from Claude Code" }
          ]
        }
      ]
    )

    activity.execute(project_id: project.id).dig(:prs_to_trigger, 0, :triggers).map { |trigger| trigger[:type] }
  end

  def ci_action_review_settings(action_name = "codex-review")
    {
      "enabled" => true,
      "wait_for_reviews" => true,
      "methods" => {
        "ci_action" => { "enabled" => true, "action_name" => action_name }
      }
    }
  end
end
