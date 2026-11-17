# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec OPERATOR-INBOX-026
RSpec.describe "Inbox member navigation", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) do
    create(:project, account:, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end
  let(:questions_body) do
    "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What behavior is expected?\n"
  end
  let!(:first_issue) do
    create(:issue, :needs_input, project:, title: "First question", body: questions_body,
      needs_input_since: 2.hours.ago)
  end
  let(:second_issue) do
    create(:issue, :needs_input, project:, title: "Second question", body: questions_body,
      needs_input_since: 1.hour.ago)
  end
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    allow(GithubClient).to receive(:new).and_return(github_client)
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  def member_path(issue)
    inbox_entry_path("#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:#{issue.id}",
      project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
  end

  def ordered_issues
    second_issue
    Inbox::Queue.call(user:, project:, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND).map(&:issue)
  end

  def decision_brief_lane_cases
    other_project = create(:project, account:, created_by: user, owner: "acme", repo: "beta",
      auto_pick_enabled: true, active: true)
    question = create(:issue, :needs_input, project: other_project, title: "Beta question", body: questions_body)
    manual = create(:issue, project:, github_number: 301, paid_state: "manual_review", manual_review_reason: "Review the recorded recovery.")
    closeout = create(:issue, project:, github_number: 302, paid_state: "in_progress")
    create(:issue, :pull_request, project:, github_number: 303, github_state: "closed", pr_review_phase: "merged", parent_issue_id: closeout.id)
    action_issue = create(:issue, project:, github_number: 304)
    notification = create(:notification, :error, account:, subject: action_issue, source: "quality_auto_resume_cooldown", blocking: true,
      action_url: project_path(project), title: "Resolve quality pause",
      metadata: { "recommended_action" => "Open project settings", "remediation_steps" => [ "Open project settings" ] })
    [
      [ Inbox::Queue::PARTIAL_CLOSEOUT_KIND, closeout.id, closeout, project, {
        decision: "Choose how to finish the remaining acceptance criteria.",
        unknown: "Who will own the remaining acceptance work?", waiting: "Remaining acceptance work is waiting for an owner.",
        action: "Resolve remaining work", next_state: "The issue can be reassessed after the remaining work is recorded.",
        primary_control: "Link prerequisite"
      } ],
      [ Inbox::Queue::MANUAL_REVIEW_KIND, manual.id, manual, project, {
        decision: "Choose whether and how Paid should resume.", unknown: "Which authorized recovery path should Paid follow?",
        waiting: "Automation is waiting for an authorized recovery decision.", action: "Review recovery",
        next_state: "Paid will only resume through the selected recovery path.",
        primary_control: "View Issue"
      } ],
      [ Inbox::Queue::ACTION_REQUIRED_KIND, notification.id, action_issue, project, {
        decision: "Complete the required remediation.", recommendation: "Open project settings",
        reason: "This is the first recorded remediation step.", waiting: "Work is waiting for the required remediation.",
        action: "Complete remediation", next_state: "Blocked work can resume after the remediation is recorded.",
        primary_control: "Open linked action"
      } ],
      [ Inbox::Queue::CLARIFYING_QUESTIONS_KIND, question.id, question, other_project, {
        decision: "What behavior is expected?", unknown: "What behavior is expected?", waiting: "Work is waiting for your answer.",
        action: "Answer the question", next_state: "Paid can continue with your answer.",
        primary_control: "Submit Answers"
      } ]
    ]
  end

  def expect_decision_brief_for(kind:, entry_record_id:, selected_project:, expected:)
    visit inbox_entry_path("#{kind}:#{entry_record_id}", project_id: selected_project.id, kind:)
    expect_decision_brief(expected:, selected_project:)
    expect(page).to have_button("Copy link to this item")
    expect_one_clear_primary_action(expected.fetch(:primary_control))
  end

  # The sticky action area must present exactly one visually clear primary
  # action per lane: the designated control, filled with the primary palette,
  # while every other projected control keeps the neutral outline styling.
  def expect_one_clear_primary_action(label)
    bar = find("[data-inbox-actions-target='bar']", visible: true)
    primaries = bar.all("[data-inbox-primary-action]")
    expect(primaries.size).to eq(1)
    primary = primaries.first
    expect(primary.text.presence || primary[:value]).to eq(label)
    expect(primary[:class]).to include("bg-indigo-600")
    expect(primary[:class]).to include("text-white")

    secondary_classes = bar.all("button:not([data-inbox-primary-action]), a:not([data-inbox-primary-action])")
      .map { |control| control[:class] }
    expect(secondary_classes).to all(include("bg-white"))
    expect(secondary_classes.join(" ")).not_to include("bg-indigo-600")
  end

  def expect_decision_brief(expected:, selected_project:)
    brief = find("[data-testid='inbox-decision-brief']")
    expect(brief).to have_text("Goal: No approved intent is available for this work item.")
    expect(brief).to have_text("Intent source: Intent unavailable")
    expect(brief).to have_text("Repository: #{selected_project.full_name}")
    expect(brief).to have_text(expected.fetch(:decision))
    expect(brief).to have_text("Paid recommends: #{expected.fetch(:recommendation)}") if expected[:recommendation]
    expect(brief).to have_text(expected.fetch(:reason)) if expected[:reason]
    expect(brief).to have_text("Unknown: #{expected.fetch(:unknown)}") if expected[:unknown]
    expect(brief).to have_text("Waiting: #{expected.fetch(:waiting)}")
    expect(brief).to have_text(expected.fetch(:action))
    expect(brief).to have_text("Afterward: #{expected.fetch(:next_state)}")
  end

  def switch_project_filter(from:, to:)
    click_button "Filters"
    within("dialog[aria-label='Inbox filters']") do
      uncheck from.full_name
      check to.full_name
      click_button "Apply filters"
    end
  end

  it "keeps the first collection selection shareable and advances subsequent selection through browser history" do
    initial_issue, next_issue = ordered_issues
    page.current_window.resize_to(1440, 1000)
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(page).to have_css("#inbox-detail h2", text: initial_issue.title)
    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))

    within("#inbox-list") { click_link next_issue.title }
    expect(page).to have_css("#inbox-detail h2", text: next_issue.title)
    expect(page).to have_current_path(member_path(next_issue))

    page.go_back
    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))
    expect(page).to have_css("#inbox-detail h2", text: initial_issue.title)

    page.go_forward
    expect(page).to have_current_path(member_path(next_issue))
    expect(page).to have_css("#inbox-detail h2", text: next_issue.title)
  end

  it "copies the canonical member URL for the first collection selection" do
    initial_issue = ordered_issues.first
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    expect(page).to have_css("#inbox-detail h2", text: initial_issue.title)

    copy_button = find_button("Copy link to this item")
    expect(copy_button["aria-describedby"]).to eq("inbox-copy-link-status")
    expect(copy_button["data-inbox-master-detail-copy-link-url"]).to eq(member_path(initial_issue))
    click_button "Copy link to this item"

    expect(page).to have_css("#inbox-copy-link-status", text: "Link copied.")
  end

  # @spec OPERATOR-INBOX-027
  it "keeps every selected-item action accessible at the top on narrow screens" do
    page.current_window.resize_to(390, 844)
    visit member_path(first_issue)

    action_area = find("[data-inbox-actions-target='bar']:not([hidden])")
    expect(action_area).to have_button("Submit Answers")
    expect(action_area[:class]).to include("flex-wrap")
    expect(action_area[:class]).to include("sticky")
  end

  # @spec OPERATOR-INBOX-026 @spec OPERATOR-INBOX-027
  it "presents decision context and a visible next action across the four closeout lanes while switching projects" do
    page.current_window.resize_to(390, 844)
    lane_cases = decision_brief_lane_cases
    lane_cases.first(3).each do |kind, entry_record_id, _issue, selected_project, expected|
      expect_decision_brief_for(kind:, entry_record_id:, selected_project:, expected:)
    end

    other_kind, _entry_record_id, other_issue, other_project, other_expected = lane_cases.last
    visit member_path(first_issue)
    switch_project_filter(from: project, to: other_project)

    expect(page).to have_css("#inbox-detail h2", text: other_issue.title)
    expect(page).to have_current_path(inbox_path(kinds: [ other_kind ], project_ids: [ other_project.id ], sort: Inbox::Queue::DEFAULT_SORT))
    expect_decision_brief(expected: other_expected, selected_project: other_project)
    expect_one_clear_primary_action(other_expected.fetch(:primary_control))

    page.go_back
    expect(page).to have_current_path(member_path(first_issue))
    expect(page).to have_css("#inbox-detail h2", text: first_issue.title)
    expect(page).to have_button("Filters", text: project.full_name)

    page.go_forward
    expect(page).to have_current_path(inbox_path(kinds: [ other_kind ], project_ids: [ other_project.id ], sort: Inbox::Queue::DEFAULT_SORT))
    expect(page).to have_css("#inbox-detail h2", text: other_issue.title)
  end

  it "uses the member URL for a dependency cycle and retains it on mobile" do
    first = create(:issue, project:, github_state: "open", title: "Cycle first")
    second = create(:issue, project:, github_state: "open", title: "Cycle second")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle_entry = Inbox::Queue.call(user:, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND).sole

    page.current_window.resize_to(390, 844)
    visit inbox_path(kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND)
    expect(page).to have_no_css("#inbox-detail-pane", visible: true)

    within("#inbox-list") { click_link "Dependency cycle" }
    expect(page).to have_css("#inbox-detail h2", text: "Dependency cycle")

    copy_button = find_button("Copy link to this item")
    expect(copy_button["data-inbox-master-detail-copy-link-url"]).to eq(inbox_entry_path(cycle_entry.id,
      kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND))
    click_button "Copy link to this item"
    expect(page).to have_css("#inbox-copy-link-status", text: "Link copied.")

    expect(page).to have_current_path(inbox_entry_path(cycle_entry.id, kind: Inbox::Queue::DEPENDENCY_CYCLE_KIND))
    expect(page).to have_css("#inbox-detail h2", text: "Dependency cycle")
  end

  it "uses the existing safe fallback when a copied member URL is no longer actionable" do
    visit member_path(first_issue)
    expect(page).to have_css("#inbox-detail h2", text: "First question")

    first_issue.update_columns(github_state: "closed")
    visit member_path(first_issue)

    expect(page).to have_current_path(inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND))
    expect(page).to have_no_css("#inbox-detail h2", text: "First question")
  end
end
