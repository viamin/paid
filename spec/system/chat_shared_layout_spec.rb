# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# System coverage of the Chat pages going through the shared
# `app/views/shared/_list_detail_shell.html.erb` partial. Pairs with
# `spec/system/dashboard_inbox_spec.rb`, which covers the same shared
# partial from the Inbox side, so a future change to the shared grid,
# pane chrome, empty state, or active-row treatment is caught when only
# one of the two screens drifts.
#
# The `chat_sessions_path` index controller falls through to a JSON
# response unless the Accept header advertises HTML, and the system
# driver's rack-test adapter does not. Tests therefore visit the URL
# with `format: :html` to force the HTML branch.
#
# @spec LIST-DETAIL-001 @spec LIST-DETAIL-002 @spec LIST-DETAIL-003
# @spec LIST-DETAIL-005 @spec LIST-DETAIL-006
RSpec.describe "Chat shared list-and-detail layout", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  # The chat `index` redirect path only renders the empty-state template
  # for users who cannot create chat sessions; otherwise the controller
  # creates or selects a session and 302s to `/chat/:id`. A `:viewer`
  # user has no create permission, so the index page renders the empty
  # state through the shared shell.
  let(:user) { create(:user, :viewer, account: account, email: "chat-layout@example.com", password: "password123") }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "renders the chat empty state through the shared shell with the shared empty-state chrome" do
    visit chat_sessions_path(format: :html)

    document = Nokogiri::HTML(page.body)
    shell = document.at_css("#chat-detail")
    empty_card = document.at_css("#chat-detail .rounded-xl.border-dashed")

    expect(shell).to be_present
    expect(shell[:class]).to include("rounded-xl", "border", "bg-white")
    expect(empty_card).to be_present
    expect(page).to have_content("No conversation selected")
  end

  it "renders the shared grid wrapper around the chat panes on the chat show page" do
    show_user = create(:user, :owner, account: account, email: "chat-show@example.com", password: "password123")
    Warden.test_reset!
    login_as(show_user, scope: :user)
    session = create(:chat_session, account: account, created_by: show_user, container_capability: "none")

    visit chat_session_path(session, format: :html)

    document = Nokogiri::HTML(page.body)
    grid = document.at_css("div.grid.gap-6")
    grid_classes = grid ? grid[:class] : ""

    expect(grid).to be_present
    expect(grid_classes).to include("lg:grid-cols-[22rem_minmax(0,1fr)]")
    expect(document.at_css("#chat-list")).to be_present
    expect(document.at_css("#chat-detail")).to be_present
  end

  it "exposes the shared active-row class set on chat session cards via data-active-classes" do
    # The active-row state is applied at runtime by `chat-session-list`;
    # the server-rendered initial visit puts the shared class set on
    # `data-active-classes` so the controller toggles the same treatment
    # the Inbox list and the rest of Paid use. Pair this assertion with
    # `spec/lib/chat_session_list_controller_node_harness_spec.rb` for
    # the controller-side coverage of the same class set.
    show_user = create(:user, :owner, account: account, email: "chat-active@example.com", password: "password123")
    Warden.test_reset!
    login_as(show_user, scope: :user)
    active = create(:chat_session, account: account, created_by: show_user, container_capability: "none", title: "Active chat")
    other = create(:chat_session, account: account, created_by: show_user, container_capability: "none", title: "Other chat")

    visit chat_session_path(active, format: :html)

    document = Nokogiri::HTML(page.body)
    active_link = document.at_css(%(a#chat_session_#{active.id}))
    other_link = document.at_css(%(a#chat_session_#{other.id}))

    expect(active_link).to be_present
    expect(active_link["data-active-classes"]).to eq("bg-indigo-50 ring-1 ring-inset ring-indigo-200")
    expect(other_link).to be_present
    expect(other_link["data-active-classes"]).to eq("bg-indigo-50 ring-1 ring-inset ring-indigo-200")
  end
end
