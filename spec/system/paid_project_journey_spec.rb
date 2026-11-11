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

  # @spec LIVE-PREVIEW-012
  it "keeps the documented launch command runnable in the agent's execution container" do
    # Intentionally not derived from `Screenshots::RuntimePlan#start_command`:
    # that derivation prefers `bin/dev` whenever the file exists in the repo,
    # but the agent container (docker/agent/Dockerfile) ships neither `tmux`
    # nor Overmind, so `bin/dev` cannot start anything there. The guide must
    # keep documenting the command this container can actually run.
    journey_guide = Rails.root.join(".paid/journeys.md").read

    expect(journey_guide).to include("(bundle exec bin/rails server -b 0.0.0.0 -p 3000)")
  end
end
