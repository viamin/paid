# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-027
RSpec.describe "dashboard/_inbox_detail_actions", type: :view do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project:, github_number: 42) }
  let(:entry) do
    instance_double(Inbox::Queue::Entry,
      id: "plan_review:#{issue.id}",
      kind: Inbox::Queue::PLAN_REVIEW_KIND,
      project:,
      issue:,
      actionable?: true)
  end

  before do
    captured_user = user
    view.define_singleton_method(:current_user) { captured_user }
    allow(Inbox::ChatAction).to receive(:for).with(entry.kind).and_return(
      instance_double(Inbox::ChatAction, shared_detail?: true, label: "Discuss in chat")
    )
    allow(Inbox::InteractiveChatAccess).to receive(:allowed?).with(user:, project:).and_return(true)
    allow(Inbox::Removals::Suppression).to receive(:call).with(user:, entries: [entry]).and_return([])
  end

  it "renders authorized item controls before the details with their existing navigation semantics" do
    render partial: "dashboard/inbox_detail_actions", locals: { entry: }

    document = Nokogiri::HTML.fragment(rendered)
    toolbar = document.at_css("[data-testid='inbox-detail-actions']")

    expect(toolbar["aria-label"]).to eq("Item actions")
    expect(toolbar["class"]).to include("sticky")
    expect(toolbar.at_css(".flex")["class"]).to include("flex-wrap")
    expect(toolbar).to have_button("Discuss in chat")
    expect(toolbar.at_css("form[action='#{inbox_interactive_chat_path(entry)}']")["data-turbo-frame"]).to eq("_top")
    expect(toolbar).to have_link("View Issue", href: issue.github_url)
    expect(toolbar).to have_button("Remove from Inbox")
    expect(toolbar.at_css("form[action='#{inbox_entry_remove_path(entry.id)}']")["data-turbo-confirm"])
      .to eq("Hide this request from your Inbox? The work, its questions, and its history stay unchanged.")
  end

  it "keeps restoration in the same top action toolbar when the item is personally removed" do
    allow(Inbox::Removals::Suppression).to receive(:call).with(user:, entries: [entry]).and_return([entry.id])

    render partial: "dashboard/inbox_detail_actions", locals: { entry: }

    document = Nokogiri::HTML.fragment(rendered)
    toolbar = document.at_css("[data-testid='inbox-detail-actions']")

    expect(toolbar).to have_button("Restore to Inbox")
    expect(toolbar).not_to have_button("Remove from Inbox")
    expect(toolbar.at_css("form[action='#{inbox_entry_restore_path(entry.id)}']")["data-turbo-frame"]).to eq("_top")
  end
end
