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

  it "keeps the reason and action inside the inbox detail pane on mobile and desktop" do # @spec PARTIAL-CLOSEOUT-010
    issue = create(:issue, project:, github_number: 201, paid_state: "in_progress")
    create(:issue, :pull_request, project:, github_number: 202, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id)

    [ 375, 1024 ].each do |width|
      page.current_window.resize_to(width, 800)
      visit inbox_entry_path("partial_closeout:#{issue.id}", project_id: project.id,
        kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND)
      expect(page).to have_field("Reason for continuation", type: :textarea)

      expect(continuation_form_geometry).to include("direction" => "column", "contained" => true)
    end
  end

  def continuation_form_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const form = document.querySelector('form[action*="request_continuation"]');
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
