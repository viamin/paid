# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_inbox_progress", type: :view do
  let(:projection) do
    Inbox::ProgressProjection::Result.new(
      operating_mode: "autonomous",
      tdd_mode: "strict",
      current_head: "a" * 40,
      milestones: [ milestone ]
    )
  end

  let(:milestone) do
    Inbox::ProgressProjection::Milestone.new(
      id: "test_review",
      label: "Proposed-test review",
      state: "complete",
      evidence: [
        { source: "tdd_test_verdict", revision: "a" * 40, url: "https://github.com/acme/paid/pull/42" },
        { source: "untrusted", revision: "b" * 40, url: "javascript:alert(1)" }
      ],
      next_action: nil
    )
  end

  # @spec INBOX-PROGRESS-001
  it "renders milestone evidence and safely links GitHub evidence" do
    render partial: "dashboard/inbox_progress", locals: { projection: }

    evidence_link = Nokogiri::HTML.fragment(rendered).at_css("a[href='https://github.com/acme/paid/pull/42']")
    expect(rendered).to include("Tdd test verdict")
    expect(rendered).to include("a" * 40)
    expect(evidence_link["target"]).to eq("_blank")
    expect(evidence_link["rel"]).to eq("noopener noreferrer")
    expect(rendered).not_to include("href=\"javascript:")
  end
end
