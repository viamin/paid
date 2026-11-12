# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-FOUNDATION-012
RSpec.describe Inbox::Query do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:alpha) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:beta) { create(:project, account:, created_by: user, owner: "acme", repo: "beta") }

  def entry(id:, kind:, project:, title:, summary: nil)
    Inbox::Queue::Entry.new(id:, kind:, project:, title_text: title, summary_text: summary)
  end

  it "combines allowlisted multi-value predicates and searches Ransack project fields" do
    alpha_entry = entry(id: "clarifying_questions:1", kind: "clarifying_questions", project: alpha, title: "Choose a branch")
    beta_entry = entry(id: "manual_review:2", kind: "manual_review", project: beta, title: "Review rollout")
    excluded = entry(id: "plan_review:3", kind: "plan_review", project: beta, title: "Plan")
    query = described_class.new(
      params: { "project_id_in" => [ alpha.id, beta.id ], "kind_in" => %w[clarifying_questions manual_review], "search_cont" => "beta" },
      projects: Project.where(id: [ alpha.id, beta.id ])
    )

    expect(query.call([ alpha_entry, beta_entry, excluded ])).to eq([ beta_entry ])
  end

  it "searches only entry title and summary fields when the project does not match" do
    matching = entry(id: "clarifying_questions:1", kind: "clarifying_questions", project: alpha, title: "Review deployment", summary: "Needs a human")
    query = described_class.new(params: { "search_cont" => "deployment" }, projects: Project.where(id: alpha.id))

    expect(query.call([ matching ])).to eq([ matching ])
  end
end
