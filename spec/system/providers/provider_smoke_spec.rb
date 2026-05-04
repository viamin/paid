# frozen_string_literal: true

require "rails_helper"
require "securerandom"
require "warden/test/helpers"

RSpec.describe "Provider smoke test UI", :local_only, :provider_smoke, type: :system do
  include Warden::Test::Helpers

  let(:scenario) { ProviderSmokeHelpers.scenarios_from_env.first }
  let(:unique_suffix) { SecureRandom.hex(6) }
  let!(:account) { create(:account, slug: "provider-smoke-ui-#{unique_suffix}") }
  let!(:user) do
    create(
      :user,
      :owner,
      account: account,
      email: "provider-smoke-ui-#{unique_suffix}@example.com",
      password: "password123"
    )
  end
  let!(:provider) { ProviderSmokeHelpers.build_provider!(user: user, scenario: scenario) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
    ProviderSmokeHelpers.create_smoke_project!(user: user)
  end

  after do
    Warden.test_reset!
  end

  it "runs the provider smoke test from the providers page" do
    skip "No provider smoke scenarios configured" if scenario.nil?

    visit providers_path

    using_wait_time 90 do
      within("tr", text: provider.display_name) do
        click_button "Test Agent"
        expect(page).to have_content("Agent is healthy")
      end
    end
  rescue ProviderSmokeHelpers::ScenarioUnavailableError => e
    skip e.message
  end
end
