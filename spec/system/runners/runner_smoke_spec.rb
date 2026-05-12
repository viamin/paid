# frozen_string_literal: true

require "rails_helper"
require "securerandom"
require "warden/test/helpers"

RSpec.describe "Runner smoke test UI", :runner_smoke, type: :system do
  include Warden::Test::Helpers

  let(:scenario) { RunnerSmokeHelpers.scenarios_from_env.first }
  let(:unique_suffix) { SecureRandom.hex(6) }
  let!(:account) { create(:account, slug: "runner-smoke-ui-#{unique_suffix}") }
  let!(:user) do
    create(
      :user,
      :owner,
      account: account,
      email: "runner-smoke-ui-#{unique_suffix}@example.com",
      password: "password123"
    )
  end

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "runs the runner smoke test from the runners page" do
    skip "No runner smoke scenarios configured" if scenario.nil?

    RunnerSmokeHelpers.create_smoke_project!(user: user)
    runner = RunnerSmokeHelpers.build_runner!(user: user, scenario: scenario)

    visit runners_path

    using_wait_time 90 do
      within("tr", text: runner.display_name) do
        click_button "Test Agent"
        expect(page).to have_content("Agent is healthy")
      end
    end
  rescue RunnerSmokeHelpers::ScenarioUnavailableError => e
    skip e.message
  end
end
