# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-027 OPERATOR-INBOX-028
RSpec.describe Inbox::Search do
  let(:alpha) { build_stubbed(:project, id: 11, owner: "acme", repo: "alpha") }
  let(:beta) { build_stubbed(:project, id: 12, owner: "acme", repo: "beta") }
  let(:entry_class) { Inbox::Queue::Entry }
  let(:entries) do
    [
      entry_class.new(id: "clarifying_questions:1", kind: "clarifying_questions", project: alpha, title_text: "Alpha title", summary_text: "Need input", tasks: [], questions: []),
      entry_class.new(id: "manual_review:2", kind: "manual_review", project: beta, title_text: "Beta title", summary_text: "Review deployment", tasks: [], questions: [])
    ]
  end

  it "unions multiple kinds and projects using the allowlisted Ransack-compatible predicates" do
    result = described_class.new(params: { q: { kind_in: %w[clarifying_questions manual_review], project_id_in: [ "11", "12" ] } }).call(entries)

    expect(result.map(&:id)).to contain_exactly("clarifying_questions:1", "manual_review:2")
  end

  it "searches project, title, and summary while ignoring unsupported predicates" do
    result = described_class.new(params: { q: { search_cont: "deployment", id_eq: "1" } }).call(entries)

    expect(result.map(&:id)).to eq([ "manual_review:2" ])
  end
end
