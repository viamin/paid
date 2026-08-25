# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Project warden security scan toggle", system_driver: :rack_test, type: :system do # @spec QUALITY-LOOPS-007
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let!(:project) { create(:project, account: account, github_token: github_token) }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
    allow(Projects::Screenshots::RepoConfig).to receive(:call)
      .and_return(Projects::Screenshots::RepoConfig::Result.new(config: {}, content: nil, error: nil))
  end

  after do
    Warden.test_reset!
  end

  describe "project pre-commit requirements page" do
    it "renders the security scan section" do
      visit project_pre_commit_requirements_path(project)
      expect(page).to have_content("Security Scan (Warden)")
      expect(page).to have_content("Enable warden security scan")
    end

    it "shows the default command as a hint" do
      visit project_pre_commit_requirements_path(project)
      expect(page).to have_content(PreCommitRequirement::WARDEN_DEFAULT_COMMAND)
    end
  end

  describe "toggling the warden scan on" do
    context "when no warden_scan requirement exists" do
      it "creates an enabled requirement with the warn default" do
        visit project_pre_commit_requirements_path(project)

        check "Enable warden security scan"
        select "Warn (log result, do not block)", from: "warden_scan_failure_behavior"
        click_button "Save Security Scan"

        expect(page).to have_content("Pre-commit requirement created")

        req = project.pre_commit_requirements.find_by(name: "warden_scan")
        expect(req).to be_present
        expect(req.check_type).to eq("security_scan")
        expect(req).to be_enabled
        expect(req.command).to eq("warden-scan")
        expect(req.failure_behavior).to eq("warn")
      end
    end

    context "when a disabled warden_scan requirement exists" do
      let!(:requirement) do
        create(:pre_commit_requirement, :warden_scan, :project_level,
          project: project, enabled: false, failure_behavior: "warn")
      end

      it "enables the existing requirement" do
        visit project_pre_commit_requirements_path(project)

        check "Enable warden security scan"
        click_button "Save Security Scan"

        requirement.reload
        expect(requirement).to be_enabled
      end
    end
  end

  describe "toggling the warden scan off" do
    let!(:requirement) do
      create(:pre_commit_requirement, :warden_scan, :project_level,
        project: project, enabled: true, failure_behavior: "warn")
    end

    it "disables the requirement" do
      visit project_pre_commit_requirements_path(project)

      expect(page).to have_checked_field("Enable warden security scan")
      uncheck "Enable warden security scan"
      click_button "Save Security Scan"

      expect(page).to have_content("Pre-commit requirement updated")
      requirement.reload
      expect(requirement).not_to be_enabled
    end
  end
end
