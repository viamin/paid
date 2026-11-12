# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Query do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:alpha) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha", active: true) }
  let(:beta) { create(:project, account:, created_by: user, owner: "acme", repo: "beta", active: true) }

  def entry(id:, kind:, project:, title:, summary: nil, issue: nil)
    Inbox::Queue::Entry.new(id:, kind:, project:, issue:, record: issue, waiting_since: Time.current,
      questions: [], tasks: [], title_text: title, summary_text: summary, action_url: nil)
  end

  # @spec INBOX-FOUNDATION-012
  it "unions selected projects and kinds before applying the Ransack-backed text predicate" do
    alpha_issue = create(:issue, project: alpha, title: "Alpha incident")
    beta_issue = create(:issue, project: beta, title: "Beta deployment")
    entries = [
      entry(id: "clarifying_questions:1", kind: "clarifying_questions", project: alpha, title: "Alpha incident", issue: alpha_issue),
      entry(id: "manual_review:2", kind: "manual_review", project: beta, title: "Review deployment", summary: "Needs an operator", issue: beta_issue),
      entry(id: "action_required:3", kind: "action_required", project: beta, title: "Credential expired", summary: "Repository access")
    ]

    results = described_class.call(entries:, projects: [ alpha, beta ], kinds: %w[clarifying_questions manual_review],
      search: { "text_cont" => "beta" })

    expect(results.map(&:id)).to eq([ "manual_review:2" ])
  end

  # @spec INBOX-FOUNDATION-012
  it "searches derived entry title and summary without accepting arbitrary predicates" do
    entries = [ entry(id: "action_required:3", kind: "action_required", project: beta,
      title: "Credential expired", summary: "Repository access") ]

    expect(described_class.call(entries:, search: { "text_cont" => "repository", "id_eq" => "3" }).map(&:id))
      .to eq([ "action_required:3" ])
  end
end
