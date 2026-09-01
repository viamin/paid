# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

RSpec.describe "Project page header layout", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:, password: "password123") }
  let(:github_token) { create(:github_token, account: account) }

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path

    Warden.test_mode!
    login_as(user, scope: :user)
    page.current_window.resize_to(375, 812)
  end

  after do
    Warden.test_reset!
  end

  it "does not overflow horizontally on a narrow viewport with the project name, status badge, buttons, and a long GitHub link" do
    # @spec RAILS-CONTROL-PLANE-008
    project = create(
      :project,
      account: account,
      github_token: github_token,
      name: "paid3538projectpageheaderoverflowsonmobilewithoutseparators",
      owner: "averylongorganizationnameforoverflowtestingwithoutseparators",
      repo: "anequallylongrepositorynameforoverflowtestingwithoutseparators",
      active: true
    )

    visit project_path(project)

    expect(page).to have_css("[data-testid='project-external-links']")
    expect(page).to have_css("[data-testid='project-external-link']")
    expect(page).to have_link("Trigger Run")
    expect(page).to have_link("Edit")

    expect(settled_document_overflow).to be <= 4
  end

  def document_overflow
    page.evaluate_script(<<~JS)
      Number((document.documentElement.scrollWidth - window.innerWidth).toFixed(2))
    JS
  end

  def settled_document_overflow
    page.document.synchronize(errors: [ Capybara::ExpectationNotMet ]) do
      overflow = document_overflow
      return overflow if overflow <= 4

      raise Capybara::ExpectationNotMet, "project page layout has not settled yet: overflow=#{overflow}"
    end
  end
end
