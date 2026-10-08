# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Partial closeout continuation form", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) do
    create(:project, account:, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "keeps the reason and action inside a 300px-wide continuation section at every supported viewport width" do # @spec PARTIAL-CLOSEOUT-010
    issue = create(:issue, project:, github_number: 201, paid_state: "in_progress")
    create(:issue, :pull_request, project:, github_number: 202, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id)

    [ 320, 375, 640, 768, 1024, 1280 ].each do |width|
      page.current_window.resize_to(width, 800)
      visit inbox_entry_path("partial_closeout:#{issue.id}", project_id: project.id,
        kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
      expect(page).to have_field("Reason for continuation", type: :textarea)

      expect(continuation_form_geometry(section_width: 300)).to include(
        "direction" => "column", "contained" => true
      )
    end
  end

  it "keeps the editable completion rationale labeled and above its submit at mobile widths" do # @spec PARTIAL-CLOSEOUT-014
    issue = create(:issue, project:, github_number: 211, paid_state: "in_progress")
    create(:issue, :pull_request, project:, github_number: 212, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id)

    [ 320, 375, 640 ].each do |width|
      page.current_window.resize_to(width, 800)
      visit inbox_entry_path("partial_closeout:#{issue.id}", project_id: project.id,
        kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      form = page.find("form[action='#{resolve_closeout_project_agent_runs_path(project)}']")
      textarea = form.find("textarea[name='reason']")
      submit = form.find("input[type='submit']")

      expect(textarea[:id]).to eq(form.find("label", text: "Completion rationale")[:for])
      expect(textarea.native.attribute("aria-describedby")).to be_present
      expect(textarea.bounds.bottom).to be <= submit.bounds.top
    end
  end

  it "keeps the link-prerequisite input labeled and usable at mobile widths" do # @spec PARTIAL-CLOSEOUT-016
    issue = create(:issue, project:, github_number: 221, paid_state: "in_progress")
    create(:issue, :pull_request, project:, github_number: 222, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id)

    [ 320, 375 ].each do |width|
      page.current_window.resize_to(width, 800)
      visit inbox_entry_path("partial_closeout:#{issue.id}", project_id: project.id,
        kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      form = page.find("form[action='#{link_prerequisite_project_agent_runs_path(project)}']")
      input = form.find("input[name='depends_on']")
      label = form.find("label", text: "Link a prerequisite")

      expect(input[:id]).to eq(label[:for])
      expect(input.native.attribute("aria-describedby")).to be_present
      expect(input.bounds.width).to be > 0
    end
  end

  def continuation_form_geometry(section_width:)
    page.evaluate_script(<<~JS)
      (() => {
        const form = document.querySelector('form[action*="request_continuation"]');
        form.style.width = '#{section_width}px';
        const reason = form.querySelector('textarea[name="reason"]');
        const submit = form.querySelector('input[type="submit"]');
        const bounds = form.getBoundingClientRect();
        const within = (element) => {
          const rect = element.getBoundingClientRect();
          return rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1;
        };

        return {
          direction: getComputedStyle(form).flexDirection,
          contained: within(reason) && within(submit) &&
            reason.getBoundingClientRect().bottom <= submit.getBoundingClientRect().top
        };
      })()
    JS
  end
end
