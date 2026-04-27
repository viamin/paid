# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authentication", type: :system do
  let!(:account) { create(:account) }
  let!(:user) do
    create(:user, :owner, account: account, email: "owner@example.com", password: "password123")
  end

  describe "signing in" do
    it "lets a user sign in with valid credentials and lands them on the dashboard" do
      visit new_user_session_path

      fill_in "Email", with: user.email
      fill_in "Password", with: "password123"
      click_button "Sign in"

      expect(page).to have_current_path(root_path, ignore_query: true)
      expect(page).to have_content(user.email)
      expect(page).to have_button("Sign out")
    end

    it "rejects invalid credentials and re-renders the form with an error" do
      visit new_user_session_path

      fill_in "Email", with: user.email
      fill_in "Password", with: "wrong-password"
      click_button "Sign in"

      expect(page).to have_current_path(new_user_session_path, ignore_query: true)
      expect(page).to have_content("Invalid email or password")
      expect(page).not_to have_button("Sign out")
    end
  end

  describe "signing out" do
    it "signs the user out and returns them to a guest view" do
      visit new_user_session_path
      fill_in "Email", with: user.email
      fill_in "Password", with: "password123"
      click_button "Sign in"
      expect(page).to have_button("Sign out")

      first(:button, "Sign out").click

      expect(page).not_to have_button("Sign out")
      expect(page).to have_link("Sign in") | have_content("Sign in")
    end
  end
end
