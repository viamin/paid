# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cross-tenant isolation", type: :system do
  let!(:account_a) { create(:account, name: "Account A") }
  let!(:user_a)    { create(:user, :owner, account: account_a, email: "a@example.com", password: "password123") }
  let!(:project_a) { create(:project, account: account_a, name: "Project A") }

  let!(:account_b) { create(:account, name: "Account B") }
  let!(:project_b) { create(:project, account: account_b, name: "Project B") }

  it "lets a signed-in user see their own account's project but 404s on another account's project" do
    visit new_user_session_path
    fill_in "Email", with: user_a.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
    expect(page).to have_button("Sign out")

    visit project_path(project_a)
    expect(page).to have_content(project_a.name)
    expect(page).not_to have_content(project_b.name)

    visit project_path(project_b)
    expect(page.status_code).to eq(404)
    expect(page).not_to have_content(project_b.name)
  end

  it "scopes the projects index to the signed-in user's account" do
    visit new_user_session_path
    fill_in "Email", with: user_a.email
    fill_in "Password", with: "password123"
    click_button "Sign in"
    expect(page).to have_button("Sign out")

    visit projects_path
    expect(page).to have_content(project_a.name)
    expect(page).not_to have_content(project_b.name)
  end
end
