# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec OPERATOR-INBOX-027
RSpec.describe "Inbox detail action area", :js, system_driver: :paid_cuprite, type: :system do
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
    allow(GithubClient).to receive(:new).and_return(instance_double(GithubClient, issue_comments: []))
  end

  after { Warden.test_reset! }

  it "keeps every rendered action in the sticky header and activates the original chat action" do
    issue = create(:issue, :needs_input, project:, title: "Header actions", body: questions_body)

    visit inbox_entry_path("clarifying_questions:#{issue.id}", project_id: project.id,
      kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    expect(page).to have_css("[data-testid='inbox-detail-actions']")
    expect(action_counts).to eq(source_action_count)
    expect(page.find("[data-testid='inbox-detail-actions']")).to have_css("[aria-label='Item actions']")
    expect(page.find("[data-testid='inbox-detail-actions']")).to have_button("Answer in chat")

    page.find("[data-testid='inbox-detail-actions']").click_button("Answer in chat")
    expect(page).to have_css("[data-controller~='chat']")
  end

  it "wraps header actions without horizontal overflow at desktop and narrow widths" do
    issue = create(:issue, :needs_input, project:, title: "Responsive actions", body: questions_body)

    [ 1280, 320 ].each do |width|
      page.current_window.resize_to(width, 800)
      visit inbox_entry_path("clarifying_questions:#{issue.id}", project_id: project.id,
        kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

      expect(page).to have_css("[data-testid='inbox-detail-actions']")
      expect(action_area_geometry).to include("sticky" => true, "overflow" => 0)
    end
  end

  def source_action_count
    page.evaluate_script(<<~JS)
      document.querySelectorAll("[data-inbox-detail-actions-target='source'] a[href], [data-inbox-detail-actions-target='source'] button, [data-inbox-detail-actions-target='source'] input[type='submit']").length
    JS
  end

  def action_counts
    page.evaluate_script("document.querySelectorAll(\"[data-testid='inbox-detail-actions'] button\").length")
  end

  def action_area_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const area = document.querySelector("[data-testid='inbox-detail-actions']");
        const style = window.getComputedStyle(area);
        return {
          sticky: style.position === "sticky",
          overflow: Math.max(0, Math.ceil(document.documentElement.scrollWidth - window.innerWidth))
        };
      })()
    JS
  end

  def questions_body
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
    BODY
  end
end
