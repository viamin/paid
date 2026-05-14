# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Project bundle performance dashboard", system_driver: :rack_test, type: :system do
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

  it "links from the project page and shows sparse dashboard guidance" do
    experiment = create(:configuration_experiment,
      account: account,
      status: "running",
      min_samples_per_variant: 2)
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: experiment.control_value,
      is_control: true)
    create(:configuration_experiment_variant,
      configuration_experiment: experiment,
      config_value: JSON.generate(8000))

    visit project_path(project)
    click_link "Bundle Analysis"

    expect(page).to have_current_path(project_bundle_performance_dashboard_path(project))
    expect(page).to have_content("Bundle Performance Analysis")
    expect(page).to have_content("Sparse Evidence Summary")
    expect(page).to have_content("Knowledge Token Budget")
    expect(page).to have_content("Needs more data")
  end
end
