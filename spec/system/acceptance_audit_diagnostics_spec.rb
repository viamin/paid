# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec PARTIAL-CLOSEOUT-058
RSpec.describe "Acceptance audit diagnostic layout", :js, system_driver: :paid_cuprite, type: :system do
  include Warden::Test::Helpers

  let(:user) { create(:user, :owner) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:run) do
    create(:agent_run, project:, status: "failed", reconciliation: { "acceptance_audit_failure" => {
      "category" => "invalid_assessment", "provider" => "p" * 200, "model" => "glm-5.3",
      "request_id" => "request-5184", "attempt_id" => "attempt-5184",
      "invalid_fields" => [ { "path" => "criteria[0].#{'x' * 200}", "expected" => "e" * 200, "actual" => "string" } ],
      "raw_output" => "private-response-5184"
    } })
  end

  before do
    skip "Chromium is not available for Cuprite" unless chromium_path
    Warden.test_mode!
    login_as(user, scope: :user)
  end

  after { Warden.test_reset! }

  it "keeps long recorded fields contained and exposes correlation identities by keyboard" do
    [ 1440, 390, 320 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit project_agent_run_path(project, run)
      within("section[aria-label='Assessment diagnostics']") do
        expect(page).to have_content("glm-5.3")
        expect(page).to have_no_content("private-response-5184")
        expect(page).to have_no_content("request-5184")
        # Cuprite's element send_keys clicks first, which would toggle the
        # native disclosure once before Enter toggled it back closed.
        find("summary").execute_script("this.focus()")
        page.driver.browser.keyboard.type(:enter)
        expect(page).to have_content("request-5184")
        expect(page).to have_content("attempt-5184")
      end
      expect(diagnostic_geometry).to include("contained" => true, "fields_contained" => true)
    end
  end

  def diagnostic_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const section = document.querySelector("section[aria-label='Assessment diagnostics']");
        const rect = section.getBoundingClientRect();
        return {
          contained: rect.left >= 0 && rect.right <= innerWidth + 1,
          fields_contained: section.scrollWidth <= section.clientWidth + 1
        };
      })()
    JS
  end
end
