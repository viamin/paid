# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Project screenshot settings", type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let!(:project) { create(:project, account: account, github_token: github_token) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after do
    Warden.test_reset!
  end

  it "toggles screenshot settings and saves the selected driver" do
    visit edit_project_path(project)

    check "Enable screenshots for this project"
    choose "Cuprite"
    fill_in "Setup Commands", with: "bin/setup --skip-server\nbin/rails db:prepare"
    click_button "Save Changes"

    expect(page).to have_content("Project was successfully updated.")
    expect(project.reload.screenshot_settings).to include(
      "enabled" => true,
      "driver" => "cuprite",
      "setup_commands" => [ "bin/setup --skip-server", "bin/rails db:prepare" ]
    )
  end

  it "runs framework detection from the settings page" do
    allow(Projects::Screenshots::DetectFramework).to receive(:call).and_return(
      Projects::Screenshots::DetectFramework::Result.new(
        framework: "Rails",
        confidence: "high",
        driver: "cuprite",
        service_dependencies: [ "postgres" ],
        setup_commands: [ "bin/setup --skip-server" ],
        suggested_config: { "driver" => "cuprite" },
        suggested_yaml: "driver: cuprite\n",
        detected_at: Time.current.iso8601
      )
    )

    visit edit_project_path(project)
    click_button "Auto-detect"

    expect(page).to have_content("Detected Rails with high confidence.")
    expect(page).to have_content("Suggested .paid/screenshots.yml")
    expect(project.reload.screenshot_settings.dig("detection", "framework")).to eq("Rails")
  end
end
