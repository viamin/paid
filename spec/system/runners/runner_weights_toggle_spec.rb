# frozen_string_literal: true

require "rails_helper"
require "warden/test/helpers"

# @spec RUNNER-WEIGHTS-001
#
# Requires a real, JavaScript-capable browser driver (Cuprite/Chromium) to
# exercise the Stimulus controller. When no Chromium binary is available,
# spec/support/capybara.rb falls back to :rack_test, which cannot run
# JavaScript, so these examples are skipped in that case rather than
# asserting a false negative. See .github/workflows/system_tests.yml, which
# locates a Chromium-family browser when one is available.
RSpec.describe "Runner weight inputs", type: :system do
  include Warden::Test::Helpers

  let(:user) { create(:user) }
  let(:notice_text) { "Manual weight inputs are read-only until you turn it off" }
  let(:weight_input_selector) { "input[name^='user_setting[runner_weights]']" }

  before do
    allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])

    Warden.test_mode!
    login_as(user, scope: :user)

    user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)
  end

  after do
    Warden.test_reset!
  end

  # Assertions use Capybara's auto-retrying `have_css`/`have_no_css` matchers
  # (instead of a one-shot `all(...).to all(be_disabled)` snapshot) so they
  # wait for the Stimulus controller's DOM mutation to land instead of racing
  # it, which is what made this spec flaky under a real browser driver.
  it "re-enables weight inputs immediately when auto-weight is unchecked, and disables them again on re-check" do
    skip "Requires a JavaScript-capable driver" if SYSTEM_DRIVER == :rack_test

    user.settings.update!(auto_weight_enabled: true)

    visit runners_path

    expect(page).to have_css("#{weight_input_selector}:disabled", minimum: 1)
    expect(page).to have_no_css("#{weight_input_selector}:enabled")
    expect(page).to have_text(notice_text)

    uncheck "Auto-balance weights based on usage quotas"

    expect(page).to have_css("#{weight_input_selector}:enabled", minimum: 1)
    expect(page).to have_no_css("#{weight_input_selector}:disabled")
    expect(page).not_to have_text(notice_text)

    check "Auto-balance weights based on usage quotas"

    expect(page).to have_css("#{weight_input_selector}:disabled", minimum: 1)
    expect(page).to have_no_css("#{weight_input_selector}:enabled")
    expect(page).to have_text(notice_text)
  end
end
