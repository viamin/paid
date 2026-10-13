# frozen_string_literal: true

require "rails_helper"

# System-level coverage of the inbox split-pane page. Verifies that the
# desktop split is rendered with both panes, that the inline one-page form
# is present, and that the master/detail collapse is wired for mobile via
# the inbox-master-detail Stimulus controller.
#
# Pairs with `spec/system/chat_shared_layout_spec.rb`, which covers the
# same shared `app/views/shared/_list_detail_shell.html.erb` partial from
# the Chat side, so a future change to the shared grid, pane chrome,
# empty state, or active-row treatment is caught when only one of the two
# screens drifts.
#
# @spec LIST-DETAIL-007
RSpec.describe "Inbox split pane", system_driver: :rack_test, type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account, email: "owner@example.com", password: "password123") }
  let!(:project) do
    create(:project, account: account, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end

  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
      2. Should this be behind a flag?
    BODY
  end
  # Factory projects come with a github_token; the new context_markdown accessor
  # in ClarifyingQuestions::Load tries to fetch issue comments for every
  # clarifying-question entry. Stub the client so the inbox page can build
  # under WebMock without reaching for the network.
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  it "renders the desktop split-pane with the inline one-page answer form" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit inbox_path(
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    expect(page).to have_content("Inbox")
    expect(page).to have_content("Alpha question")
    form = page.find(%(form[action="#{project_issue_clarifying_questions_path(project, project.issues.first)}"]))

    expect(form).to have_field("inbox", type: :hidden, with: "1")
    expect(form).to have_field("inbox_project_id", type: :hidden, with: project.id.to_s)
    expect(form).to have_field("inbox_kind", type: :hidden, with: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    expect(form).to have_css("textarea[name='answers[]']", count: 2)
    expect(form).to have_button("Submit Answers")
  end

  # @spec LIST-DETAIL-007
  it "renders Inbox in the shared viewport-bound shell with independent pane scroll regions" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit inbox_path(
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    document = Nokogiri::HTML(page.body)
    grid = document.at_css("div.grid.gap-6")

    expect(grid).to be_present
    expect(grid[:class]).to include("lg:h-[calc(100dvh-12rem)]")
    expect(document.at_css("#inbox-list > div")[:class]).to include("lg:overflow-y-auto")
    expect(document.at_css("#inbox-detail-pane > div")[:class]).to include("lg:overflow-y-auto")
  end

  # @spec LIST-DETAIL-007 @spec QUESTION-EXPLORATION-015
  # Regression for #4374 (PR review): `<turbo-frame>` has no app- or
  # gem-level CSS rule, so it defaults to `display: inline` and its height
  # is content-based. The shared shell's `[data-controller~="chat"]` rule
  # sets `--chat-panel-height: 100%` unconditionally at `lg`+, so an
  # embedded chat panel inside the `<turbo-frame id="inbox-detail">` would
  # resolve `height: 100%` to `auto` — dropping the panel to content height
  # and turning the inner `lg:overflow-y-auto` wrapper into a second
  # scroll container in front of the transcript. The host page gives the
  # turbo-frame `block h-full` so the shared list-detail grid track carries
  # through the frame and the panel's `100%` resolves to the wrapper (the
  # grid track) at desktop.
  it "gives the inbox-detail turbo-frame a definite height so an embedded chat panel resolves --chat-panel-height against the shared grid track" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit inbox_path(
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    document = Nokogiri::HTML(page.body)
    frame = document.at_css("turbo-frame#inbox-detail")

    expect(frame).to be_present
    expect(frame[:class]).to include("block")
    expect(frame[:class]).to include("h-full")
  end

  # @spec LIST-DETAIL-007 @spec QUESTION-EXPLORATION-015
  # Regression for #4374 (PR review): the "Answer in chat" affordance on a
  # clarifying-question entry POSTs to the chat endpoint, which redirects
  # to `chat_session_path(chat, frame: "inbox-detail")`. The chat show
  # controller sees the `frame` param and renders `chat_sessions/_frame`,
  # which wraps the chat panel in `<turbo-frame id="inbox-detail">`. Turbo
  # extracts the panel and replaces the host frame's contents in place; the
  # host frame's `block h-full` classes (asserted by the preceding test)
  # are preserved through the replacement, so the panel's inline `height:
  # var(--chat-panel-height, ...)` resolves to `100%` of the shared grid
  # track at `lg`+ and the inner `lg:overflow-y-auto` wrapper stays the
  # only scroll region the composer depends on. Direct GET to the
  # frame-scoped chat session URL — what Turbo would receive as the
  # follow-up request after the chat action's 302 — verifies that the
  # chat panel itself wires `--chat-panel-height` through `var(...)` with
  # the viewport-subtraction fallback, so the host frame's definite
  # height can resolve it at `lg`+.
  it "renders the embedded chat panel inside the inbox-detail turbo-frame with --chat-panel-height wired to 100% at desktop" do
    issue = create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
    chat_session = create(
      :chat_session,
      account: account,
      created_by: user,
      project: project,
      container_capability: "none",
      clarifying_question_issue: issue
    )

    sign_in_as(user)
    visit chat_session_path(chat_session, format: :html, frame: "inbox-detail")

    document = Nokogiri::HTML(page.body)
    frame = document.at_css("turbo-frame#inbox-detail")
    chat_panel = frame ? frame.at_css("div[data-controller='chat']") : nil

    expect(frame).to be_present
    expect(chat_panel).to be_present
    expect(chat_panel[:style]).to include("var(--chat-panel-height")
    expect(chat_panel[:style]).to include("calc(100dvh - var(--chat-panel-offset-top, 0px) - var(--chat-panel-bottom-space, 2rem))")
  end

  it "renders a labeled, multi-line continuation reason in a partial closeout" do # @spec PARTIAL-CLOSEOUT-010
    issue = create(:issue, project:, github_number: 201, paid_state: "in_progress")
    create(:issue, :pull_request, project:, github_number: 202, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id)

    sign_in_as(user)
    visit inbox_entry_path("partial_closeout:#{issue.id}", project_id: project.id,
      kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

    form = page.find(%(form[action="#{request_continuation_project_agent_runs_path(project)}"]))
    expect(form).to have_field("Reason for continuation", type: :textarea)
    expect(form).to have_button("Request continuation")
  end

  it "embeds an empty inbox_kind when the All tab is active so the submit preserves the mixed scope" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit inbox_path(project_id: project.id)

    form = page.find(%(form[action="#{project_issue_clarifying_questions_path(project, project.issues.first)}"]))

    expect(form).to have_field("inbox_kind", type: :hidden, with: "")
  end

  it "wires the mobile master-detail collapse via a Stimulus controller" do
    create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)

    sign_in_as(user)
    visit inbox_entry_path(
      "#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:#{project.issues.first.id}",
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    master_detail = page.find("[data-controller~='inbox-master-detail']", visible: false)

    expect(master_detail["data-inbox-master-detail-detail-open-value"]).to eq("true")
    expect(page).to have_link("Back to queue")
  end

  it "renders the empty inbox state without a list or detail frame" do
    sign_in_as(user)
    visit inbox_path

    expect(page).to have_content("Inbox clear")
    expect(page).to have_no_css("turbo-frame#inbox-detail")
  end

  it "renders the inline answer form with a PR badge and GitHub link when the entry is a PR" do
    create(:issue, :pull_request, :needs_input, project: project, title: "PR question", body: questions_body)
    pr = project.issues.first

    sign_in_as(user)
    visit inbox_entry_path(
      "#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:#{pr.id}",
      project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
    )

    form = page.find(%(form[action="#{project_issue_clarifying_questions_path(project, pr)}"]))

    expect(form).to have_css("textarea[name='answers[]']", count: 2)
    expect(form).to have_button("Submit Answers")
    expect(page).to have_link("View PR", href: "#{project.github_url}/pull/#{pr.github_number}")
  end
end
