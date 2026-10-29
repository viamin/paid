# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_inbox_workflow_milestones", type: :view do
  it "renders text state, exact action, expandable evidence, and the current step" do
    # @spec OPERATOR-INBOX-023
    projection = Inbox::WorkflowProjection::Result.new(milestones: [
      { key: "tests", label: "Tests", state: "completed", next_action: "Tests were approved.", evidence: [] },
      { key: "merge", label: "Merge", state: "current", next_action: "Merge this pull request on GitHub.", actor: "repository maintainer", revision: "abc123", evidence: [] }
    ])

    render partial: "dashboard/inbox_workflow_milestones", locals: { projection: }
    document = Nokogiri::HTML.fragment(rendered)

    expect(document.at_css("[role=status]").text).to include("Merge this pull request on GitHub.")
    expect(document.at_css('[aria-current="step"] summary').text).to include("Merge: Current")
    expect(document.css("details").length).to eq(2)
    expect(document.text).to include("Who can act: repository maintainer", "Revision: abc123")
  end
end
