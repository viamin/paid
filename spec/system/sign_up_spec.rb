# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sign up", type: :system do
  it "creates an account and a user, signs them in, and lands on onboarding" do
    visit new_user_registration_path

    fill_in "Account name", with: "Acme Inc"
    fill_in "Your name", with: "Ada Lovelace"
    fill_in "Email", with: "ada@example.com"
    fill_in "Password", with: "supersecret"
    fill_in "Password confirmation", with: "supersecret"
    click_button "Sign up"

    expect(page).to have_button("Sign out"),
      "expected the user to be signed in after sign-up; got page=#{page.current_path}"
    expect(page).to have_content("ada@example.com")

    user, account_name, step_count = TenantContext.with_system_access do
      u = User.find_by(email: "ada@example.com")
      [ u, u&.account&.name, u&.account&.onboarding_steps&.count ]
    end
    expect(user).to be_present
    expect(account_name).to eq("Acme Inc")
    expect(step_count).to be > 0
  end

  it "rejects sign-up when password confirmation does not match" do
    visit new_user_registration_path

    fill_in "Account name", with: "Acme Inc"
    fill_in "Your name", with: "Ada Lovelace"
    fill_in "Email", with: "ada@example.com"
    fill_in "Password", with: "supersecret"
    fill_in "Password confirmation", with: "different"
    click_button "Sign up"

    expect(page).not_to have_button("Sign out")
    expect(TenantContext.with_system_access { User.exists?(email: "ada@example.com") }).to be(false)
    expect(TenantContext.with_system_access { Account.exists?(name: "Acme Inc") }).to be(false)
  end
end
