# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-PROGRESS-004 OPERATOR-INBOX-024
RSpec.describe "dashboard/_inbox_workflow_milestones", type: :view do
  let(:milestone) do
    { name: "Merge", state: "current", label: "Your next step", reason: "Approval and merge are separate.",
      action: "Make the manual merge decision.", current: true, actor: "Repository maintainer",
      evidence: [ { source: "review", revision: "a" * 40, url: "https://github.com/acme/paid/pull/21" },
                  { source: "untrusted", revision: "b" * 40, url: "javascript:alert(1)" } ] }
  end
  let(:workflow) { { current_actions: [ milestone[:action] ], milestones: [ milestone ] } }
  let(:entry) { instance_double(Inbox::Queue::Entry, workflow_milestones: workflow) }

  it "collapses all evidence, preserves every revision and safely links only GitHub URLs" do
    render partial: "dashboard/inbox_workflow_milestones", locals: { entry: }
    document = Nokogiri::HTML.fragment(rendered)
    disclosure = document.at_css("details")

    expect(disclosure["open"]).to be_nil
    expect(disclosure.at_css("summary").text).to include("Merge", "Your next step")
    expect(document.css('[aria-current="step"]').size).to eq(1)
    expect(disclosure.css("code").map(&:text)).to eq([ "a" * 40, "b" * 40 ])
    expect(document.css("a").map { |link| link["href"] }).to eq([ "https://github.com/acme/paid/pull/21" ])
    expect(document.at_css("a")["rel"]).to eq("noopener noreferrer")
    expect(disclosure.text).to include("Repository maintainer")
  end

  it "keeps simultaneous actions separate and does not announce two unique current steps" do
    workflow[:milestones] << milestone.merge(name: "Tests", action: "Review the proposed tests.")
    workflow[:current_actions] << "Review the proposed tests."
    render partial: "dashboard/inbox_workflow_milestones", locals: { entry: }
    document = Nokogiri::HTML.fragment(rendered)

    expect(document.css('[data-testid="progress-next-action"]').map(&:text)).to eq(workflow[:current_actions])
    expect(document.css("[aria-current]")).to be_empty
    expect(document.css("details[open]")).to be_empty
  end
end
