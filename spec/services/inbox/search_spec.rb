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
end
