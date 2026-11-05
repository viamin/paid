# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::DecisionBrief do
  let(:project) { create(:project, owner: "acme", repo: "widgets") }

  def entry(kind:, issue: nil, record: nil, summary: "", questions: [], tasks: [], guidance: nil)
    Inbox::Queue::Entry.new(
      id: "#{kind}:1", kind:, project:, issue:, record:, waiting_since: Time.current,
      questions:, tasks:, summary_text: summary, title_text: issue ? nil : "Set up deployment", action_url: nil, guidance:
    )
  end

  it "builds a plain-language product-question brief without inventing a recommendation" do
    # @spec OPERATOR-INBOX-026
    issue = create(:issue, project:, title: "Choose export format")
    brief = described_class.call(entry: entry(
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue:, questions: [ "Should exports be CSV or JSON?" ]
    ))

    expect(brief.to_h).to include(
      project: "acme/widgets",
      work_item: "Choose export format",
      decision: "Answer one product question",
      focused_question: "Should exports be CSV or JSON?",
      evidence_status: "unknown"
    )
    expect(brief.recommendation).to be_nil
    expect(brief.focused_question).to eq("Should exports be CSV or JSON?")
    expect(brief.list_label).to include("acme/widgets", "Choose export format", "Answer one product question")
  end

  it "uses current manual-review state as the recommendation evidence" do
    # @spec OPERATOR-INBOX-026
    issue = create(:issue, :needs_input, project:, title: "Repair the import")
    brief = described_class.call(entry: entry(
      kind: Inbox::Queue::MANUAL_REVIEW_KIND, issue:, record: issue,
      summary: "The last analysis needs a human decision."
    ))

    expect(brief.to_h).to include(
      decision: "Review the stopped work",
      recommendation: "Review the stop reason, then resume analysis if it still applies.",
      evidence_status: "current",
      primary_action: "Resume analysis"
    )
  end

  it "discloses unavailable evidence instead of recommending an action" do
    # @spec OPERATOR-INBOX-026
    brief = described_class.call(entry: entry(
      kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND,
      summary: "The recorded closeout evidence is unavailable."
    ))

    expect(brief.to_h).to include(
      decision: "Resolve the incomplete closeout",
      evidence_status: "unavailable",
      focused_question: "Which acceptance result is still missing?"
    )
    expect(brief.recommendation).to be_nil
  end

  it "uses persisted remediation guidance for an action-required brief" do
    # @spec OPERATOR-INBOX-026
    brief = described_class.call(entry: entry(
      kind: Inbox::Queue::ACTION_REQUIRED_KIND,
      summary: "Grant the repository permission.", tasks: [ "Grant write access" ]
    ))

    expect(brief.to_h).to include(
      decision: "Fix a blocking configuration problem",
      recommendation: "Grant the repository permission.",
      primary_action: "Fix the blocking problem",
      evidence_status: "current"
    )
  end

  it "marks a revision-bound approval recommendation stale" do
    # @spec OPERATOR-INBOX-026
    issue = create(:issue, :pull_request, project:, title: "Ship the import fix")
    brief = described_class.call(entry: entry(
      kind: Inbox::Queue::MERGE_APPROVAL_KIND, issue:, record: issue,
      guidance: { stale_approval: true, instruction: "Ask for review of the current revision." }
    ))

    expect(brief.to_h).to include(
      recommendation: "Ask for review of the current revision.",
      evidence_status: "stale"
    )
  end
end
