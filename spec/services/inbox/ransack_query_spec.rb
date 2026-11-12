# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::RansackQuery do
  let(:entry_class) { Struct.new(:id, :kind, :project, :title, :summary, keyword_init: true) }
  let(:project_class) { Struct.new(:id, :full_name, keyword_init: true) }

  let(:alpha) { project_class.new(id: 1, full_name: "acme/alpha") }
  let(:beta) { project_class.new(id: 2, full_name: "acme/beta") }
  let(:entries) do
    [
      entry_class.new(id: "clarifying_questions:1", kind: "clarifying_questions", project: alpha,
        title: "Review deployment", summary: "Needs a rollout answer"),
      entry_class.new(id: "manual_review:2", kind: "manual_review", project: beta,
        title: "Fix billing", summary: "Round limit reached")
    ]
  end

  # @spec OPERATOR-INBOX-028
  it "composes allowlisted Ransack predicates for multiple projects, kinds, and search" do
    result = described_class.call(entries:, params: {
      "project_id_in" => [ "1", "2" ],
      "kind_in" => [ "clarifying_questions", "manual_review" ],
      "search_cont" => "deployment"
    })

    expect(result.map(&:id)).to eq([ "clarifying_questions:1" ])
  end

  # @spec OPERATOR-INBOX-028
  it "ignores predicates and values outside its explicit allowlist" do
    result = described_class.call(entries:, params: {
      "project_id_eq" => "2",
      "kind_in" => [ "not_a_kind" ],
      "record_sql" => "DROP TABLE issues"
    })

    expect(result).to match_array(entries)
  end
end
