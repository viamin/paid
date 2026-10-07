# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_inbox_detail_clarifying_questions", type: :view do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project) }
  let(:entry) do
    Inbox::Queue::Entry.new(
      id: "clarifying_questions:#{issue.id}",
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      project: project,
      issue: issue,
      record: issue,
      waiting_since: nil,
      questions: [],
      tasks: [],
      summary_text: nil,
      title_text: nil,
      action_url: nil
    )
  end

  def render_detail
    render partial: "dashboard/inbox_detail_clarifying_questions",
      locals: { entry: entry, scoped_project: nil, selected_kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND }
    Nokogiri::HTML.fragment(rendered)
  end

  # @spec OPERATOR-INBOX-002I
  it "renders the Answer in chat button for a project collaborator without an account owner/admin role" do
    collaborator = create(:user, account: account)
    create(:project_membership, :member, user: collaborator, project: project)
    view.define_singleton_method(:current_user) { collaborator }

    document = render_detail

    form = document.at_css(%(form[action="#{project_issue_clarifying_questions_chat_path(project, issue)}"]))
    expect(form).to be_present
    expect(form.at_css("button").text).to include("Answer in chat")
  end

  it "hides the Answer in chat button for a user with no project or account role" do
    project # ensure the account's first user (the project creator/owner) exists before the outsider
    outsider = create(:user, account: account)
    view.define_singleton_method(:current_user) { outsider }

    document = render_detail

    expect(document.at_css(%(form[action="#{project_issue_clarifying_questions_chat_path(project, issue)}"]))).to be_nil
  end
end
