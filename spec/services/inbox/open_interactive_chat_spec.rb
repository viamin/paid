# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::OpenInteractiveChat do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }
  let(:issue) do
    create(:issue, :needs_input, project:, body: "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What changed?\n")
  end
  let(:entry) do
    issue
    Inbox::Queue.call(user:, project:).first
  end

  it "creates and audits the current user's active chat for an inbox item" do
    # @spec QUESTION-EXPLORATION-001
    chat = described_class.call(user:, entry:)

    expect(chat).to have_attributes(
      created_by: user,
      project: project,
      inbox_item_key: entry.id,
      status: "active"
    )
    expect(chat.opened_at).to be_present
    expect(chat.inbox_item_metadata).to include("kind" => entry.kind, "issue_id" => issue.id)
  end

  it "reuses the active chat and creates a replacement after archive" do
    # @spec QUESTION-EXPLORATION-001
    first = described_class.call(user:, entry:)

    expect(described_class.call(user:, entry:)).to eq(first)

    ChatSessions::Archive.call(chat_session: first)

    expect(described_class.call(user:, entry:)).not_to eq(first)
  end

  it "resumes the same transcript after the idle reaper closes it" do
    # @spec QUESTION-EXPLORATION-001
    first = described_class.call(user:, entry:)
    message = create(:chat_message, chat_session: first, role: "user", content: "Keep investigating")
    first.update!(idle_timeout_at: 1.minute.ago)
    ChatSessions::IdleReaperJob.perform_now
    expect(first.reload).to be_closed

    resumed = described_class.call(user:, entry:)

    expect(resumed).to eq(first)
    expect(resumed).to be_active
    expect(resumed.closed_at).to be_nil
    expect(resumed.messages).to include(message)
  end

  it "does not allow a viewer to create an inbox chat" do
    # @spec QUESTION-EXPLORATION-007
    viewer = create(:user, :viewer, account:)

    expect { described_class.call(user: viewer, entry:) }.to raise_error(Pundit::NotAuthorizedError)
  end

  it "returns a closed workspace transcript for explicit workspace recovery" do
    # @spec QUESTION-EXPLORATION-001
    chat = create(:chat_session, :closed, :workspace, account:, created_by: user, project:,
      inbox_item_key: entry.id, container_capability: "stopped", container_id: nil, workspace_volume: nil)

    expect(described_class.call(user:, entry:)).to eq(chat)
    expect(chat.reload).to be_closed
    expect(chat).to be_container_stopped
  end

  it "selects the most recently updated active transcript without modifying older ones" do
    # @spec QUESTION-EXPLORATION-001
    older = described_class.call(user:, entry:)
    older.update!(updated_at: 1.hour.ago)
    newer = create(:chat_session, account:, created_by: user, project:, inbox_item_key: entry.id)

    expect(described_class.call(user:, entry:)).to eq(newer)
    expect(older.reload).to be_active
  end

  # @spec OPERATOR-INBOX-002F
  it "reuses a retry-limited investigation chat with a reason-specific title" do
    issue.update!(
      github_number: 4632,
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: "All available runners reached the per-issue retry cap (3).",
      runner_retry_abandonment_count: 4
    )
    retry_entry = Inbox::Queue.call(user:, project:, kind: Inbox::Queue::RETRY_LIMITED_KIND).sole

    first = described_class.call(user:, entry: retry_entry)
    second = described_class.call(user:, entry: retry_entry)

    expect(second).to eq(first)
    expect(first).to have_attributes(
      inbox_item_key: "retry_limited:#{issue.id}",
      title: "#{project.full_name}#4632: retry exhaustion chat"
    )
    expect(first.inbox_item_metadata).to include("issue_id" => issue.id, "return_count" => 3)
  end

  # @spec OPERATOR-INBOX-002F
  it "titles a push-blocked investigation chat with its reason" do
    issue.update!(
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} missing workflows permission"
    )
    retry_entry = Inbox::Queue.call(user:, project:, kind: Inbox::Queue::RETRY_LIMITED_KIND).sole

    chat = described_class.call(user:, entry: retry_entry)

    expect(chat.title).to eq("#{project.full_name}##{issue.github_number}: push blocked chat")
  end

  # @spec OPERATOR-INBOX-002F
  it "records a zero return count on a first-time abandonment" do
    issue.update!(
      runner_retry_abandoned_at: Time.current,
      runner_retry_abandon_reason: "All available runners reached the per-issue retry cap (3).",
      runner_retry_abandonment_count: 1
    )
    retry_entry = Inbox::Queue.call(user:, project:, kind: Inbox::Queue::RETRY_LIMITED_KIND).sole

    chat = described_class.call(user:, entry: retry_entry)

    expect(chat.inbox_item_metadata).to include("return_count" => 0)
  end

  # @spec OPERATOR-INBOX-002I
  # The intent_conformance lane stores an Inbox::IntentConformance::Snapshot
  # (a plain data object) in `record`, not an ActiveRecord. audit_metadata must
  # read the snapshot's `id`/`class` defensively so opening chat for that lane
  # does not 500 on the first click.
  it "creates a chat for an intent_conformance entry whose record is a Snapshot, not an AR record" do
    project.update!(auto_merge_mode: "all")
    pr = create_intent_conformance_pull_request
    entry = inbox_entry(kind: Inbox::Queue::INTENT_CONFORMANCE_KIND)

    chat = described_class.call(user:, entry:)

    expect(chat).to have_attributes(inbox_item_key: entry.id, status: "active", project: project)
    expect(chat.inbox_item_metadata).to include("kind" => Inbox::Queue::INTENT_CONFORMANCE_KIND, "issue_id" => pr.id)
    expect(chat.inbox_item_metadata).not_to have_key("record_id")
    expect(chat.inbox_item_metadata).to include("record_type" => "Inbox::IntentConformance::Snapshot")
  end

  # @spec OPERATOR-INBOX-002I
  # The escalated_pr lane stores a Dashboard::BlockedPullRequests::Entry (also
  # a plain Data object) in `record`. audit_metadata must read it defensively.
  it "creates a chat for an escalated_pr entry whose record is a BlockedPullRequests Entry" do
    pr = create_escalated_pull_request
    entry = inbox_entry(kind: Inbox::Queue::ESCALATED_PR_KIND)
    expect(entry.record).to be_a(Dashboard::BlockedPullRequests::Entry)

    chat = described_class.call(user:, entry:)

    expect(chat).to have_attributes(inbox_item_key: entry.id, status: "active", project: project)
    expect(chat.inbox_item_metadata).to include("kind" => Inbox::Queue::ESCALATED_PR_KIND, "issue_id" => pr.id)
    expect(chat.inbox_item_metadata).not_to have_key("record_id")
    expect(chat.inbox_item_metadata).to include("record_type" => "Dashboard::BlockedPullRequests::Entry")
  end

  def create_intent_conformance_pull_request
    pr = create(
      :issue,
      :pull_request,
      project: project,
      github_number: 51,
      last_scanned_head_sha: "sha1",
      auto_merge_evaluated_at: Time.current,
      auto_merge_blockers: {
        "failed" => [
          { "signal" => "intent_conformance_ok", "reason_code" => "intent_conformance_blocked" }
        ],
        "not_evaluated" => []
      }
    )
    create(:intent_conformance_verdict, :material_drift, issue: pr, pr_head_sha: "sha1")
    pr
  end

  def create_escalated_pull_request
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: 91,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      labels: [ "paid-generated", "paid-automation", "paid-escalated" ]
    )
  end

  def inbox_entry(kind:)
    Inbox::Queue.call(user:, project:, kind:).sole
  end
end
