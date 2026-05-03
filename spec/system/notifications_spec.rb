# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notifications", type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account, email: "notify@example.com", password: "password123") }

  before do
    create(:notification, account: account, title: "Mobile scroll test")
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  describe "mobile horizontal scrolling", :js do
    it "wraps the table in a horizontally scrollable container" do
      skip "requires a real browser (Cuprite/Chromium)" if SYSTEM_DRIVER == :rack_test

      visit notifications_path
      expect(page).to have_content("Mobile scroll test")

      page.driver.resize(375, 812) # iPhone-sized viewport

      scroll_width = page.evaluate_script(
        "document.querySelector('.overflow-x-auto').scrollWidth"
      )
      client_width = page.evaluate_script(
        "document.querySelector('.overflow-x-auto').clientWidth"
      )

      expect(scroll_width).to be > client_width
    end
  end
end
