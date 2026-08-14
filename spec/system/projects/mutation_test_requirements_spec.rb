# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Project mutation testing toggle", system_driver: :rack_test, type: :system do
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
    it "renders the mutation testing section" do
      visit project_pre_commit_requirements_path(project)
      expect(page).to have_content("Mutation Testing")
      expect(page).to have_content("Enable mutation testing")
    end

    it "shows the default command as a hint" do
      visit project_pre_commit_requirements_path(project)
      expect(page).to have_content(PreCommitRequirement::MUTATION_TEST_DEFAULT_COMMAND)
    end
  end

  describe "toggling mutation testing on" do
    context "when no mutation_test requirement exists" do
      it "creates an enabled requirement" do
        visit project_pre_commit_requirements_path(project)

        check "Enable mutation testing"
        fill_in "mutation_test_command", with: "bundle exec mutant run --since HEAD~1 --use rspec"
        select "Warn (log result, do not block)", from: "mutation_test_failure_behavior"
        click_button "Save Mutation Testing"

        expect(page).to have_content("Pre-commit requirement created")

        req = project.pre_commit_requirements.find_by(check_type: "mutation_test")
        expect(req).to be_present
        expect(req).to be_enabled
        expect(req.command).to eq("bundle exec mutant run --since HEAD~1 --use rspec")
        expect(req.failure_behavior).to eq("warn")
      end
    end

    context "when a disabled mutation_test requirement exists" do
      let!(:requirement) do
        create(:pre_commit_requirement, :mutation_test, :project_level,
          project: project, enabled: false, failure_behavior: "warn")
      end

      it "enables the existing requirement" do
        visit project_pre_commit_requirements_path(project)

        check "Enable mutation testing"
        click_button "Save Mutation Testing"

        requirement.reload
        expect(requirement).to be_enabled
      end
    end
  end

  describe "toggling mutation testing off" do
    let!(:requirement) do
      create(:pre_commit_requirement, :mutation_test, :project_level,
        project: project, enabled: true, failure_behavior: "block")
    end

    it "disables the requirement" do
      visit project_pre_commit_requirements_path(project)

      expect(page).to have_checked_field("Enable mutation testing")
      uncheck "Enable mutation testing"
      click_button "Save Mutation Testing"

      expect(page).to have_content("Pre-commit requirement updated")
      requirement.reload
      expect(requirement).not_to be_enabled
    end
  end

  describe "updating the command" do
    let!(:requirement) do
      create(:pre_commit_requirement, :mutation_test, :project_level,
        project: project, enabled: true, failure_behavior: "warn")
    end

    it "saves the updated command" do
      visit project_pre_commit_requirements_path(project)

      fill_in "mutation_test_command", with: "bundle exec mutant run --jobs 4"
      click_button "Save Mutation Testing"

      requirement.reload
      expect(requirement.command).to eq("bundle exec mutant run --jobs 4")
    end
  end
end
