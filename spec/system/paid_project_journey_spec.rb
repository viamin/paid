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
  it "documents a launch command the agent's execution container can run" do
    journey_guide = Rails.root.join(".paid/journeys.md").read
    log_path = Regexp.escape(AgentRuns::VerificationPrompt::APP_LOG_PATH)
    launch_command = journey_guide[/^\((.+)\) > #{log_path}/, 1]

    # The agent execution container (docker/agent/Dockerfile) ships the
    # Ruby/Rails toolchain but neither tmux nor Overmind, so `bin/dev` cannot
    # start the application there. `Screenshots::RuntimePlan` cannot supply this
    # command: its generic preference order picks `bin/dev` whenever the file
    # exists in the repository.
    expect(launch_command).to eq("bundle exec bin/rails server -b 0.0.0.0 -p 3000")
  end

  # @spec LIVE-PREVIEW-012
  it "overrides the verification prompt's generic preferred start command" do
    journey_guide = Rails.root.join(".paid/journeys.md").read

    # The prompt's generic derivation prefers `bin/dev`, which the agent
    # container cannot run. The guide has to say it overrides that command,
    # or the agent is left choosing between the prompt's launch pattern and
    # the guide's.
    expect(journey_guide).to include("verification prompt's generic preferred start command")
    expect(journey_guide).to include("`bin/dev`")
  end
end
