# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Paid project detail verification journey", system_driver: :rack_test, type: :system do
  # @spec LIVE-PREVIEW-012
  let(:account) { Account.find_by!(slug: Screenshots::SeedData::PaidJourney::ACCOUNT_SLUG) }
  let(:user) { account.users.find_by!(email: Screenshots::SeedData::PaidJourney::USER_EMAIL) }
  let(:project) { account.projects.find_by!(name: Screenshots::SeedData::PaidJourney::PROJECT_NAME) }

  before do
    Screenshots::SeedData::PaidJourney.call
  end

  after do
    Screenshots::SeedData::PaidJourney.cleanup!
  end

  it "signs in and reaches a seeded project detail from Projects" do
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: Screenshots::SeedData::PaidJourney::USER_PASSWORD
    click_button "Sign in"

    visit projects_path
    click_link project.name

    expect(page).to have_current_path(project_path(project))
    expect(page).to have_content(project.name)
  end

  it "keeps the documented launch command aligned with the runtime plan" do
    runtime_plan = Screenshots::RuntimePlan.call(project:, repo_path: Rails.root)
    journey_guide = Rails.root.join(".paid/journeys.md").read

    expect(runtime_plan.start_command).to eq("PORT=3000 bin/dev")
    expect(journey_guide).to include("(PORT=3000 bin/dev)")
  end
end
