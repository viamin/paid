# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Plain-language quality resume", system_driver: :rack_test, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) do
    create(:project, account:, created_by: user, quality_paused_at: 1.hour.ago,
      quality_pause_metadata: { "threshold" => 0.5 })
  end

  before do
    Warden.test_mode!
    login_as(user, scope: :user)
    allow(Projects::ForkParentPrefill).to receive(:call)
      .and_return(Projects::ForkParentPrefill::Prefill.unavailable("not_stubbed"))
    allow(Projects::Screenshots::RepoConfig).to receive(:call)
      .and_return(Projects::Screenshots::RepoConfig::Result.new(config: {}, content: nil, error: nil))
  end

  after { Warden.test_reset! }

  # @spec SETTINGS-COPY-002
  it "explains and performs the primary resume action" do
    visit edit_project_path(project)

    expect(page).to have_content("This lets Paid schedule automatic work for this project again. It does not start a run now.")
    expect(page).to have_button("Resume automatic work")
    expect(page.find_button("Resume automatic work")["data-turbo-confirm"])
      .to eq("Resume automatic work for this project? This allows future automatic work; it does not start a run now.")

    click_button "Resume automatic work"

    expect(page).to have_content("Quality pause was resumed.")
    expect(TenantContext.with_system_access { Project.find(project.id) }).not_to be_quality_paused
  end
end
