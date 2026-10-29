# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_inbox_detail_manual_review", type: :view do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner) }

  def render_detail(issue:, questions:)
    entry = Inbox::Queue::Entry.new(
      id: "manual_review:#{issue.id}",
      kind: Inbox::Queue::MANUAL_REVIEW_KIND,
      project:,
      issue:,
      record: issue,
      waiting_since: nil,
      questions:,
      tasks: [],
      summary_text: nil,
      title_text: nil,
      action_url: nil
    )
    allow(entry).to receive(:manual_review_comment_url).and_return(nil)
    view.define_singleton_method(:current_user) { owner }
    policy_double = Struct.new(:run_agent?).new(true)
    view.define_singleton_method(:policy) { |_| policy_double }

    render partial: "dashboard/inbox_detail_manual_review",
      locals: { entry:, scoped_project: nil, selected_kind: Inbox::Queue::MANUAL_REVIEW_KIND }
    Nokogiri::HTML.fragment(rendered)
  end

  # @spec OPERATOR-INBOX-002L
  it "does not render stale enhancement questions for an unknown manual-review hold" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: "scanner evidence is incomplete",
      needs_input_questions: [ "What should this enhancement do?" ])

    document = render_detail(issue:, questions: issue.needs_input_questions)

    expect(document.at_css("form[action*='clarifying_questions']")).to be_nil
    expect(document.text).to include("provenance is unknown")
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "renders questions for an enhancement manual-review hold" do
    issue = create(:issue, project:, paid_state: "manual_review",
      needs_input_questions: [ "What should this enhancement do?" ])

    document = render_detail(issue:, questions: issue.needs_input_questions)

    expect(document.at_css("form[action*='clarifying_questions']")).to be_present
  end
end
