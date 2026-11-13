# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Search do
  # @spec INBOX-FOUNDATION-012
  it "uses the allowlisted Ransack text predicate for repository and issue-title matches" do
    account = create(:account)
    user = create(:user, account:)
    matching_project = create(:project, account:, created_by: user, owner: "acme", repo: "payments")
    other_project = create(:project, account:, created_by: user, owner: "acme", repo: "console")
    matching_issue = create(:issue, project: matching_project, title: "Rotate signing key")
    other_issue = create(:issue, project: other_project, title: "Refresh dashboard")
    entries = [ matching_issue, other_issue ].map do |issue|
      Inbox::Queue::Entry.new(id: "manual_review:#{issue.id}", kind: "manual_review", project: issue.project,
        issue:, record: issue, questions: [], tasks: [])
    end

    expect(described_class.call(entries:, query: { "text_cont" => "payments" })).to eq([ entries.first ])
    expect(described_class.call(entries:, query: { "text_cont" => "signing" })).to eq([ entries.first ])
    expect(described_class.call(entries:, query: { "paid_state_eq" => "manual_review" })).to eq(entries)
  end

  # @spec INBOX-FOUNDATION-012
  it "matches displayed titles and summaries for entries without issues" do
    title_entry = Inbox::Queue::Entry.new(
      id: "feature_decision:1", kind: "feature_decision", title_text: "Approve passkey rollout",
      summary_text: "Ready for approval"
    )
    summary_entry = Inbox::Queue::Entry.new(
      id: "layered_verification_finding:2", kind: "layered_verification_finding", title_text: "Verification finding",
      summary_text: "Checkout obligations diverged"
    )
    entries = [ title_entry, summary_entry ]

    expect(described_class.call(entries:, query: { "text_cont" => "passkey" })).to eq([ title_entry ])
    expect(described_class.call(entries:, query: { "text_cont" => "obligations" })).to eq([ summary_entry ])
  end

  # @spec INBOX-FOUNDATION-012
  it "searches every project and issue represented by a dependency cycle" do
    account = create(:account)
    user = create(:user, account:)
    primary_project = create(:project, account:, created_by: user, owner: "acme", repo: "alpha")
    other_project = create(:project, account:, created_by: user, owner: "acme", repo: "payments")
    primary_issue = create(:issue, project: primary_project, title: "Refresh dashboard")
    other_issue = create(:issue, project: other_project, title: "Rotate signing key")
    cycle = Issues::DependencyCycles::Cycle.new(
      account:, issues: [ primary_issue, other_issue ], path: [], path_edges: [], effective_edges: [],
      downstream_issues: [], detected_at: Time.current, occurrence: "cycle", visible_parent_project_ids: nil
    )
    entry = Inbox::Queue::Entry.new(
      id: cycle.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND, project: cycle.project,
      issue: nil, record: cycle, title_text: cycle.title, summary_text: cycle.summary
    )

    expect(described_class.call(entries: [ entry ], query: { "text_cont" => "payments" })).to eq([ entry ])
    expect(described_class.call(entries: [ entry ], query: { "text_cont" => "signing" })).to eq([ entry ])
  end
end
