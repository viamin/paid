# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec PROJECT-CREATION-013
#
# Exercises the repository-selector Stimulus controller end to end on the
# successful-fetch path: choosing a credential triggers the JSON fetch and
# the controller renders the options from `this.repositories`. This guards
# against regressions where renderRepoSelect references a stale `repos`
# argument, which surfaces to the user as the generic "Failed to load
# repositories" error message instead of the repository list.
#
# Requires a JavaScript-capable browser driver (Cuprite/Chromium); skips when
# none is available. See spec/support/capybara.rb and
# .github/workflows/system_tests.yml.
RSpec.describe "Project form repository selector", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  let(:repositories) do
    [
      {
        "id" => 101,
        "full_name" => "acme/alpha",
        "name" => "alpha",
        "owner" => "acme",
        "default_branch" => "main",
        "private" => false,
        "created_at" => "2026-09-01T12:00:00Z"
      },
      {
        "id" => 102,
        "full_name" => "acme/beta",
        "name" => "beta",
        "owner" => "acme",
        "default_branch" => "develop",
        "private" => true,
        "created_at" => "2026-09-03T12:00:00Z"
      }
    ]
  end

  let(:token) do
    create(:github_token, account: account, created_by: user,
      accessible_repositories: repositories, repositories_synced_at: Time.current)
  end

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    Warden.test_mode!
    login_as(user, scope: :user)
    token
  end

  after do
    Warden.test_reset!
  end

  def repository_option_labels
    all("[role='option']").map(&:text)
  end

  it "populates the repository combobox after a successful fetch and records the selection" do
    visit new_project_path

    select token.name, from: "project_github_token_id"

    expect(page).to have_text("2 repositories available.")
    find("#repository_selection").click
    expect(page).to have_css("[role='option']", count: 2)
    expect(repository_option_labels).to eq([ "acme/alpha", "acme/beta (private)" ])

    find("[role='option']", text: "acme/beta (private)").trigger("mousedown")

    expect(page).to have_css('input[name="project[owner]"][value="acme"]', visible: :all)
    expect(page).to have_css('input[name="project[repo]"][value="beta"]', visible: :all)
    expect(page).to have_css('input[name="project[github_id]"][value="102"]', visible: :all)
    expect(page).to have_css('input[name="project[default_branch]"][value="develop"]', visible: :all)
  end

  it "re-orders repositories by recency when the sort selection changes" do
    visit new_project_path

    select token.name, from: "project_github_token_id"
    expect(page).to have_text("2 repositories available.")
    expect(page).to have_select("repository_sort", disabled: false)

    select "Recently created", from: "repository_sort"
    find("#repository_selection").click
    expect(page).to have_css("[role='option']", count: 2)

    expect(repository_option_labels).to eq([ "acme/beta (private)", "acme/alpha" ])
  end
end
