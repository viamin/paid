# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::ScanPaidPrsActivity do # @spec FOCUSED-RUN-010
  include_context "with stable PR scanner project"

  let(:activity) { described_class.new }
  let(:octokit_client) { instance_double(Octokit::Client) }
  let(:github_client) { instance_double(GithubClient, client: octokit_client) }

  let(:comment) do
    OpenStruct.new(
      id: 7157569292,
      user: OpenStruct.new(login: "viamin"),
      body: "Please fix the error handling in the parser module",
      created_at: 30.minutes.ago
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(rate_limit_remaining!: 100, check_run_log: "")
    allow(github_client).to receive_messages(remove_label_from_issue: nil, add_labels_to_issue: nil)
    allow(github_client).to receive(:issue_events).and_return([])
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    create(:issue, :pull_request,
      project: project, github_number: 42,
      labels: [ "paid-generated", "paid-automation" ], paid_state: "completed")
    # The completed run that admitted the no-change follow-up; it predates
    # the comment's consumption window only once the follow-up consumes it.
    create(:agent_run, :completed,
      project: project, source_pull_request_number: 42,
      goal: "create_pr", focus: "conversation",
      completed_at: 1.hour.ago)
    stub_pr_signals
  end

  def stub_pr_signals(comments: [ comment ], reviews: default_clean_copilot_review,
    checks: [ { name: "ci", conclusion: "success" } ])
    pr_data = OpenStruct.new(
      base: OpenStruct.new(ref: "main"),
      head: OpenStruct.new(sha: "abc123", repo: OpenStruct.new(fork: false)),
      mergeable: true,
      draft: false,
      number: 42,
      user: OpenStruct.new(login: "someone-else")
    )
    recent = comments
    multi_page = false
    recent.define_singleton_method(:multi_page?) { multi_page }

    allow(github_client).to receive(:pull_request).with(project.full_name, 42).and_return(pr_data)
    allow(github_client).to receive(:check_runs_for_ref).with(project.full_name, "abc123").and_return(checks)
    allow(github_client).to receive(:workflow_runs_for_sha).with(project.full_name, "abc123").and_return([])
    allow(github_client).to receive(:review_threads).with(project.full_name, 42).and_return([])
    allow(github_client).to receive(:recent_issue_comments).with(project.full_name, 42).and_return(recent)
    allow(github_client).to receive(:issue_comments).with(project.full_name, 42).and_return(comments)
    allow(github_client).to receive(:pull_request_reviews).with(project.full_name, 42).and_return(reviews)
    allow(github_client).to receive(:commit).with(project.full_name, "abc123").and_return(
      OpenStruct.new(commit: OpenStruct.new(committer: OpenStruct.new(date: 2.hours.ago)))
    )
  end

  def default_clean_copilot_review
    [ { id: 100, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
      body: "Copilot reviewed 5 out of 5 changed files and generated no comments.", submitted_at: 1.hour.ago } ]
  end

  def trigger_types(result)
    result.fetch(:prs_to_trigger).flat_map { |trigger| trigger[:triggers].map { |t| t[:type] } }
  end

  def create_no_change_run!(focus: "conversation", completed_at: 20.minutes.ago, status: "no_output",
    error_message: "no_changes", pr_number: 42, proj: project)
    create(:agent_run,
      project: proj, source_pull_request_number: pr_number,
      goal: "create_pr", focus: focus,
      status: status, error_message: error_message,
      started_at: 25.minutes.ago, completed_at: completed_at)
  end

  describe "conversation feedback consumption after no-change follow-ups" do
    let(:operator) { create(:user, :owner, account: project.account) }

    it "records an explicitly selected current operator report without queueing coding work" do # @spec FOCUSED-RUN-015
      pull_request = project.issues.find_by!(github_number: 42)
      event = PullRequests::RecordOperatorAcceptanceReport.call(
        pull_request:, actor: operator, comment_id: comment.id,
        environment: "devcontainer", results: "63/0 source acceptance", unrun_capabilities: [ "CI" ]
      ).event

      result = activity.execute(project_id: project.id)

      expect(result.fetch(:prs_to_trigger)).to eq([])
      expect(event.metadata).to include("revision" => "abc123", "comment_id" => comment.id.to_s)
      expect(AgentRun.where(project:, source_pull_request_number: 42, status: "queued")).to be_empty
    end

    it "keeps a later actionable comment distinct from a recorded operator report" do # @spec FOCUSED-RUN-015
      pull_request = project.issues.find_by!(github_number: 42)
      PullRequests::RecordOperatorAcceptanceReport.call(
        pull_request:, actor: operator, comment_id: comment.id,
        environment: "devcontainer", results: "63/0 source acceptance"
      )
      later_comment = OpenStruct.new(id: 7157569293, user: OpenStruct.new(login: "viamin"),
        body: "Please correct the remaining regression", created_at: 5.minutes.ago)
      stub_pr_signals(comments: [ comment, later_comment ])

      expect(trigger_types(activity.execute(project_id: project.id))).to include("conversation_comments")
    end

    it "retains comments arriving after prompt preparation but before no-change completion" do
      run = create_no_change_run!
      record_prompt_preparation(run, started_at: 40.minutes.ago, finished_at: 35.minutes.ago)

      expect(trigger_types(activity.execute(project_id: project.id))).to include("conversation_comments")
    end

    it "keeps same-second provider timestamps actionable when prompt ordering is ambiguous" do
      run = create_no_change_run!
      prepared_at = 25.minutes.ago.change(usec: 500_000)
      comment.created_at = prepared_at.change(usec: 0)
      record_prompt_preparation(run, started_at: prepared_at, finished_at: 24.minutes.ago)

      expect(trigger_types(activity.execute(project_id: project.id))).to include("conversation_comments")
    end

    it "does not acknowledge comments through a failed prompt preparation" do
      run = create_no_change_run!
      record_prompt_preparation(run, started_at: 25.minutes.ago, finished_at: 24.minutes.ago, status: "failed")

      expect(trigger_types(activity.execute(project_id: project.id))).to include("conversation_comments")
    end

    it "does not acknowledge comments through a preparation recorded after completion" do
      run = create_no_change_run!
      record_prompt_preparation(run, started_at: 15.minutes.ago, finished_at: 10.minutes.ago)

      expect(trigger_types(activity.execute(project_id: project.id))).to include("conversation_comments")
    end

    it "uses the newest prepared context when completion order is reversed" do
      later_completion = create_no_change_run!(completed_at: 10.minutes.ago)
      record_prompt_preparation(later_completion, started_at: 40.minutes.ago, finished_at: 35.minutes.ago)
      earlier_completion = create_no_change_run!(completed_at: 20.minutes.ago)
      record_prompt_preparation(earlier_completion, started_at: 25.minutes.ago, finished_at: 24.minutes.ago)

      expect(trigger_types(activity.execute(project_id: project.id))).not_to include("conversation_comments")
    end

    it "keeps comments actionable after a completed review-feedback run excluded them" do
      expect_conversation_feedback_after_completed_focus("review_feedback")
    end

    it "keeps comments actionable after a completed CI-fix run excluded them" do
      expect_conversation_feedback_after_completed_focus("ci_fix")
    end

    it "keeps comments actionable after a completed merge-conflict run excluded them" do
      expect_conversation_feedback_after_completed_focus("merge_conflict")
    end

    it "consumes comments older than a completed conversation-scope run" do
      create(:agent_run, :completed,
        project: project, source_pull_request_number: 42,
        goal: "create_pr", focus: "conversation",
        completed_at: 10.minutes.ago)

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).not_to include("conversation_comments")
    end

    it "keeps an eligible completed run's cutoff after later focused completions" do
      %w[review_feedback ci_fix merge_conflict].each do |focus|
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          goal: "create_pr", focus: "conversation",
          completed_at: 20.minutes.ago)
        create(:agent_run, :completed,
          project: project, source_pull_request_number: 42,
          goal: "create_pr", focus: focus,
          completed_at: 10.minutes.ago)

        result = activity.execute(project_id: project.id)

        expect(trigger_types(result)).not_to include("conversation_comments")
      end
    end

    it "consumes comments older than a terminal conversation-scope no-change run" do
      create_no_change_run!

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).not_to include("conversation_comments")
      expect(result.fetch(:prs_to_trigger)).to eq([])
    end

    it "consumes comments older than an unscoped general no-change run" do
      create_no_change_run!(focus: "general")

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).not_to include("conversation_comments")
      expect(result.fetch(:prs_to_trigger)).to eq([])
    end

    it "keeps comments newer than the no-change run actionable" do
      create_no_change_run!
      newer_comment = OpenStruct.new(
        user: OpenStruct.new(login: "viamin"),
        body: "Please also handle the retry path around the parser fallback",
        created_at: 10.minutes.ago
      )
      stub_pr_signals(comments: [ comment, newer_comment ])

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments for a review_feedback no-change run" do
      create_no_change_run!(focus: "review_feedback")

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments for a ci_fix no-change run" do
      create_no_change_run!(focus: "ci_fix")

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments for a no_output run with a non-no_changes reason" do
      create_no_change_run!(error_message: "provider_exhausted")

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments when the newest conversation run failed" do
      create_no_change_run!(status: "failed", error_message: "runner crashed")

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments while the conversation run is still running" do
      create(:agent_run,
        project: project, source_pull_request_number: 42,
        goal: "create_pr", focus: "conversation",
        status: "running", started_at: 25.minutes.ago)

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments from a no-change run on another PR" do
      create_no_change_run!(pr_number: 43)

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "does not consume comments from a no-change run on another project" do
      other_project = create(:project, auto_scan_prs: true)
      create_no_change_run!(proj: other_project)

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end

    it "keeps changes_requested from being consumed by a no-change conversation run" do
      create_no_change_run!
      stub_pr_signals(reviews: default_clean_copilot_review + [
        { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED", body: "", submitted_at: 25.minutes.ago }
      ])

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("changes_requested")
    end

    it "keeps CI failures from being consumed by a no-change conversation run" do
      create_no_change_run!
      stub_pr_signals(checks: [ { name: "ci", conclusion: "failure" } ])

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("ci_failure")
    end
  end

  def expect_conversation_feedback_after_completed_focus(focus)
    create(:agent_run, :completed,
      project: project, source_pull_request_number: 42,
      goal: "create_pr", focus: focus,
      completed_at: 10.minutes.ago)

    result = activity.execute(project_id: project.id)

    expect(trigger_types(result)).to include("conversation_comments")
  end

  def record_prompt_preparation(run, started_at:, finished_at:, status: "completed")
    AgentRunPhase.record!(agent_run: run, phase_key: "prepare_pr_prompt", phase_group: "prompt",
      started_at: started_at, finished_at: finished_at, status: status)
  end

  describe "draft-phase conversation feedback consumption" do
    before do
      issue = Issue.find_by(github_number: 42)
      issue.update!(pr_review_phase: "draft", draft_review_count: 0)
      pr_data = OpenStruct.new(
        base: OpenStruct.new(ref: "main"),
        head: OpenStruct.new(sha: "abc123", repo: OpenStruct.new(fork: false)),
        mergeable: true,
        draft: true,
        number: 42,
        user: OpenStruct.new(login: "someone-else")
      )
      allow(github_client).to receive(:pull_request).with(project.full_name, 42).and_return(pr_data)
    end

    it "does not queue another draft follow-up for the consumed comment" do
      create_no_change_run!

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).not_to include("conversation_comments")
      expect(result.fetch(:prs_to_trigger)).not_to include(hash_including(focus: "conversation"))
    end

    it "still queues a draft follow-up when the comment predates only a failed run" do
      create_no_change_run!(status: "failed", error_message: "runner crashed")

      result = activity.execute(project_id: project.id)

      expect(trigger_types(result)).to include("conversation_comments")
    end
  end
end
