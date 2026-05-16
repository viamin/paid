# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notifications", system_driver: :rack_test, type: :system do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, :owner, account: account, email: "notify@example.com", password: "password123") }

  before do
    create(:notification, account: account, title: "Mobile scroll test")
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
  end

  describe "mobile horizontal scrolling" do
    it "renders the notifications table inside a horizontal scroll wrapper" do
      visit notifications_path
      expect(page).to have_content("Mobile scroll test")

      doc = Nokogiri::HTML(page.html)
      scroll_wrapper = doc.at_css("div.overflow-x-auto > table.min-w-full")

      expect(scroll_wrapper).to be_present
      expect(scroll_wrapper["style"]).to include("min-width: 640px")
    end
  end
end
