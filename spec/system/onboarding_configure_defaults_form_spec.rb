# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Onboarding configure_defaults step", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let!(:project) { create(:project, account: account, created_by: owner) }

  before do
    Warden.test_mode!
    login_as(owner, scope: :user)
    Onboarding::StartOnboarding.call(account: account)
    %w[account_profile github_token].each do |s|
      Onboarding::CompleteStep.call(account: account, step: s)
    end
    Onboarding::CompleteStep.call(
      account: account,
      step: "first_project",
      metadata: { project_id: project.id }
    )
  end

  # @spec FEATURE-APPROVAL-004
  it "applies the suggested posture when the HTML form is submitted via the browser" do
    visit onboarding_path

    expect(page).to have_field("operating_posture", with: "human_led_feature_factory", checked: true)
    expect(page).to have_select("auto_merge_mode", selected: "off")
    expect(page).to have_select("tdd_mode", selected: "non_strict")

    patch_form = page.find(:css, %(form[action="#{onboarding_path}"][method="post"]))
    expect(patch_form).to have_field("operating_posture", with: "human_led_feature_factory")

    click_button "Set Up Defaults & Finish"

    expect(project.reload.operating_mode).to eq("human_led_feature_factory")
    expect(project.tdd_mode).to eq("non_strict")
    expect(project.auto_merge_mode).to eq("off")
  end

  # @spec FEATURE-APPROVAL-003
  it "honors explicit auto-merge and TDD selections submitted via the HTML form" do
    visit onboarding_path

    choose "Human-Led Feature Factory"
    select "all", from: "auto_merge_mode"
    select "strict", from: "tdd_mode"
    click_button "Set Up Defaults & Finish"

    expect(project.reload.auto_merge_mode).to eq("all")
    expect(project.tdd_mode).to eq("strict")
  end

  # @spec FEATURE-APPROVAL-004
  it "does not nest the posture fields inside the Skip form" do
    visit onboarding_path

    skip_form = page.find(:css, %(form[action="#{skip_onboarding_path}"]))
    expect(skip_form).to have_no_field("operating_posture")
    expect(skip_form).to have_no_field("auto_merge_mode")
    expect(skip_form).to have_no_field("tdd_mode")
  end
end
