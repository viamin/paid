# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::EntrySearch do
  let(:alpha) { build_stubbed(:project, id: 1, owner: "acme", repo: "alpha") }
  let(:beta) { build_stubbed(:project, id: 2, owner: "acme", repo: "beta") }
  let(:entry_class) do
    Struct.new(:kind, :project, :record, :title, :summary, :issue, keyword_init: true) do
      def dependency_cycle? = false
    end
  end
  let(:entries) do
    [
      entry_class.new(kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, project: alpha, title: "Alpha title", summary: "Question"),
      entry_class.new(kind: Inbox::Queue::MANUAL_REVIEW_KIND, project: beta, title: "Beta title", summary: "Needs a human"),
      entry_class.new(kind: Inbox::Queue::PLAN_REVIEW_KIND, project: beta, title: "Plan", summary: "Release checklist")
    ]
  end

  # @spec OPERATOR-INBOX-027
  it "uses allowlisted Ransack-compatible predicates to compose multi-value filters and search" do
    result = described_class.call(entries:, query: {
      "kind_in" => [ Inbox::Queue::CLARIFYING_QUESTIONS_KIND, Inbox::Queue::MANUAL_REVIEW_KIND ],
      "project_id_in" => [ beta.id.to_s ],
      "search_cont" => "human",
      "issue_title_cont" => "ignored"
    })

    expect(result).to contain_exactly(entries.second)
  end

  # @spec OPERATOR-INBOX-027
  it "does not treat unsupported predicates or invalid values as searchable fields" do
    result = described_class.call(entries:, query: {
      "kind_in" => [ "not-a-kind" ],
      "project_id_in" => [ "not-an-id" ],
      "arbitrary_sql_eq" => "anything"
    })

    expect(result).to match_array(entries)
  end
end
