# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# Exploratory reproduction for #4867: observe what the browser address bar
# actually does when an operator selects an Inbox row.
RSpec.describe "Inbox selection URL reproduction", system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:project) do
    create(:project, account:, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end
  let(:questions_body) do
    "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. What is the expected behavior?\n"
  end
  let(:github_client) { instance_double(GithubClient, issue_comments: []) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    allow(GithubClient).to receive(:new).and_return(github_client)

    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "reports the address after selecting the first and a later row" do
    first = create(:issue, :needs_input, project:, title: "Alpha question", body: questions_body)
    second = create(:issue, :needs_input, project:, title: "Beta question", body: questions_body)

    visit inbox_path
    puts "INITIAL URL: #{current_url}"
    puts "INITIAL PATH: #{page.current_path}"
    puts "ROWS: #{page.all('a[data-inbox-master-detail-target=row]').map { |a| a[:href] }.inspect}"

    within("#inbox-list") { click_link "Beta question" }
    sleep 2
    puts "AFTER CLICK URL: #{current_url}"
    puts "AFTER CLICK PATH: #{page.current_path}"
    puts "DETAIL HEADING: #{page.find('turbo-frame#inbox-detail h2', visible: :all)&.text.inspect}"
    puts "LIST PRESENT: #{page.has_css?('#inbox-list', wait: 0)}"
    puts "HISTORY LENGTH: #{page.evaluate_script('window.history.length')}"

    puts "FIRST URL: #{inbox_entry_path("clarifying_questions:#{first.id}")}"
    puts "SECOND URL: #{inbox_entry_path("clarifying_questions:#{second.id}")}"
  end
end
