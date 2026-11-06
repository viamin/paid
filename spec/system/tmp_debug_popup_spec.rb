# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "TMP debug popup", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) do
    create(:project, account:, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    allow(GithubClient).to receive(:new).and_return(github_client)

    create(
      :issue,
      :needs_input,
      project:,
      title: "Alpha question",
      body: "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What is the expected behavior?\n"
    )

    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "captures unhandled rejections during mobile row click" do
    page.current_window.resize_to(1280, 800)
    visit inbox_path(project_id: project.id, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

    page.evaluate_script(<<~JS)
      window.__rejections = [];
      window.addEventListener("unhandledrejection", (event) => {
        const reason = event.reason;
        window.__rejections.push({
          name: reason && reason.name,
          message: reason && reason.message,
          stack: reason && reason.stack ? reason.stack.split("\\n").slice(0, 6).join(" | ") : String(reason)
        });
      });
    JS

    page.current_window.resize_to(375, 812)

    expect(page).to have_css("[data-inbox-master-detail-target='list']", visible: :visible)
    expect(page).to have_css("[data-inbox-master-detail-target='detailSection']", visible: :hidden)

    page.find("[data-inbox-master-detail-target='row']", match: :first).click

    expect(page).to have_content("Back to queue")
    rejections = page.evaluate_script("JSON.stringify(window.__rejections)")
    puts "REJECTIONS: #{rejections}"
    expect(rejections).to eq("[]")
  end
end
