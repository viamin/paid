# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::PreparePrPromptActivity do
  def automation_scan_results(result)
    result.fetch(:prs_to_trigger)
  end

  def stub_requested_changes_flow(github_client)
    allow(github_client).to receive(:pull_request_reviews).and_return(
      [ { id: 1, user_login: "reviewer", state: "CHANGES_REQUESTED", body: "", submitted_at: 30.minutes.ago } ],
      [ { id: 2, user_login: "reviewer", state: "APPROVED", body: "Confirmed", submitted_at: Time.current } ]
    )
    allow(github_client).to receive(:review_threads).and_return(
      [
        {
          id: "thread_1",
          is_resolved: false,
          comments: [
            { body: "Replace this inferred rationale with the confirmed decision", path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md", line: 12, author: "reviewer" }
          ]
        }
      ],
      [
        {
          id: "thread_1",
          is_resolved: false,
          comments: [
            { body: "Replace this inferred rationale with the confirmed decision", path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md", line: 12, author: "reviewer" }
          ]
        }
      ],
      []
    )
    allow(github_client).to receive_messages(
      pull_request_files: [
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md" },
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md" },
        { filename: "AGENTS.md" }
      ],
      pull_request_file_patches: [
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md" },
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md" },
        { filename: "AGENTS.md" }
      ]
    )
    stub_planning_pr_file_contents(github_client)
  end

  # Comment-only review feedback (no CHANGES_REQUESTED review) on a docs-only
  # Planning PR must stay deferable per RDR-051 phase 4 — only a formal
  # "Request changes" review corrects an inferred decision.
  def stub_comment_only_review_flow(github_client)
    allow(github_client).to receive_messages(
      pull_request_reviews: [
        { id: 1, user_login: "reviewer", state: "COMMENTED", body: "Looks reasonable", submitted_at: 30.minutes.ago }
      ],
      review_threads: [
        {
          id: "thread_1",
          is_resolved: false,
          comments: [
            { body: "Just double-checking this looks right", path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md", line: 12, author: "reviewer" }
          ]
        }
      ],
      pull_request_files: [
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md" },
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md" },
        { filename: "AGENTS.md" }
      ],
      pull_request_file_patches: [
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md" },
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md" },
        { filename: "AGENTS.md" }
      ]
    )
    stub_planning_pr_file_contents(github_client)
  end

  def stub_requested_changes_then_comment_flow(github_client)
    allow(github_client).to receive_messages(
      pull_request_reviews: [
        { id: 1, user_login: "reviewer", state: "CHANGES_REQUESTED", body: "", submitted_at: 45.minutes.ago },
        { id: 2, user_login: "reviewer", state: "COMMENTED", body: "Still waiting on the fix", submitted_at: 15.minutes.ago }
      ],
      review_threads: [
        {
          id: "thread_1",
          is_resolved: false,
          comments: [
            { body: "Replace this inferred rationale with the confirmed decision", path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md", line: 12, author: "reviewer" }
          ]
        }
      ],
      pull_request_files: [
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md" },
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md" },
        { filename: "AGENTS.md" }
      ],
      pull_request_file_patches: [
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md" },
        { filename: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md" },
        { filename: "AGENTS.md" }
      ]
    )
    stub_planning_pr_file_contents(github_client)
  end

  def stub_planning_pr_file_contents(github_client)
    allow(github_client).to receive(:file_content)
      .with(project.full_name, path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md", ref: "abc123")
      .and_return("## Decisions\n\n- Replace inferred rationale [inferred]\n")
    allow(github_client).to receive(:file_content)
      .with(project.full_name, path: "docs/intent/lid-pr-confirmation/lid-pr-confirmation-specs.md", ref: "abc123")
      .and_return("## Open Questions\n\n- Which rationale should be confirmed?\n")
    allow(github_client).to receive(:file_content)
      .with(project.full_name, path: "AGENTS.md", ref: "abc123")
      .and_return("Agent instructions\n")
  end

  def build_followup_run(project, pull_request_issue)
    create(:agent_run, :with_git_context,
      project: project,
      issue: pull_request_issue,
      source_pull_request_number: 42,
      focus: "review_feedback")
  end

  let(:project) { create(:project, allowed_github_usernames: [ "trusteduser", "reviewer" ]) }
  let(:pull_request_issue) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      github_creator_login: "trusteduser",
      labels: [ "paid-generated", "paid-automation" ],
      pr_review_phase: "draft",
      draft_review_count: 0)
  end
  let(:completed_run) do
    create(:agent_run, :completed,
      project: project,
      issue: pull_request_issue,
      source_pull_request_number: 42,
      completed_at: 1.hour.ago)
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:prepare_activity) { described_class.new }
  let(:scan_activity) { Activities::ScanPaidPrsActivity.new }
  let(:pr_data) do
    OpenStruct.new(
      title: "docs: add LID planning artifacts",
      body: <<~MARKDOWN,
        Planning PR for LID adoption

        ## Confirm These Inferred Decisions

        - [ ] `docs/intent/lid-pr-confirmation/lid-pr-confirmation-design.md`: Replace inferred rationale
      MARKDOWN
      draft: true,
      merged: false,
      state: "open",
      mergeable: true,
      head: OpenStruct.new(ref: "paid/lid-planning", sha: "abc123"),
      base: OpenStruct.new(ref: "main")
    )
  end

  before do
    completed_run
    recent_comments = [].tap { |comments| comments.define_singleton_method(:multi_page?) { false } }
    allow(Project).to receive(:find_by).with(id: project.id).and_return(project)
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive(:pull_request).and_return(pr_data)
    allow(github_client).to receive_messages(
      rate_limit_remaining!: 100,
      check_runs_for_ref: [],
      recent_issue_comments: recent_comments,
      fetch_issue_comment_page: [],
      compare_changed_files: [],
      commit: OpenStruct.new(commit: OpenStruct.new(committer: OpenStruct.new(date: 5.minutes.ago))),
      issue: pr_data,
      issue_events: [],
      pull_request_review_requests: { users: [] }
    )
    allow(AgentRuns::UserSettingsResolver).to receive(:call)
      .and_return(OpenStruct.new(max_prompt_comments: 20, max_comment_length: 2000))
  end

  it "queues follow-up work for requested changes, prepares an intent-correction prompt, and clears after approval" do
    stub_requested_changes_flow(github_client)

    scan_result = scan_activity.execute(project_id: project.id)
    trigger = automation_scan_results(scan_result).first

    expect(trigger[:focus]).to eq("review_feedback")
    expect(trigger[:triggers].map { |entry| entry[:type] }).to include("changes_requested")

    followup_run = build_followup_run(project, pull_request_issue)
    allow(AgentRun).to receive(:find).with(followup_run.id).and_return(followup_run)

    prompt_result = prepare_activity.execute(agent_run_id: followup_run.id, rebase_succeeded: true, focus: "review_feedback")

    expect(prompt_result[:includes_review_threads]).to be(true)
    expect(followup_run.reload.custom_prompt).to include("Intent Confirmation Follow-Up")
    expect(followup_run.custom_prompt).to include("Replace the `[inferred]` marker")

    cleared_result = scan_activity.execute(project_id: project.id)

    expect(automation_scan_results(cleared_result)).to eq([])
  end

  it "does not queue a follow-up run for comment-only review feedback on a Planning PR" do
    stub_comment_only_review_flow(github_client)

    scan_result = scan_activity.execute(project_id: project.id)
    trigger_types = automation_scan_results(scan_result).flat_map { |trigger| trigger[:triggers].map { |entry| entry[:type] } }

    expect(trigger_types).not_to include("review_threads", "changes_requested")
  end

  it "keeps requested changes blocking on a Planning PR until the reviewer explicitly approves" do
    stub_requested_changes_then_comment_flow(github_client)

    scan_result = scan_activity.execute(project_id: project.id)
    trigger_types = automation_scan_results(scan_result).flat_map { |trigger| trigger[:triggers].map { |entry| entry[:type] } }

    expect(trigger_types).to include("changes_requested")
    expect(trigger_types).not_to include("review_threads")
  end
end
