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

  let!(:user) { create(:user) }
  let(:notice_text) { "Manual weight inputs are read-only until you turn it off" }

  before do
    Warden.test_mode!
    login_as(user, scope: :user)

    allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
    user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)
  end

  after do
    Warden.test_reset!
  end

  def weight_inputs
    all("input[name^='user_setting[runner_weights]']")
  end

  it "re-enables weight inputs immediately when auto-weight is unchecked, and disables them again on re-check" do
    skip "Requires a JavaScript-capable driver" if SYSTEM_DRIVER == :rack_test

    user.settings.update!(auto_weight_enabled: true)

    visit runners_path

    expect(weight_inputs).not_to be_empty
    expect(weight_inputs).to all(be_disabled)
    expect(page).to have_text(notice_text)

    uncheck "Auto-balance weights based on usage quotas"

    expect(weight_inputs).to all(be_enabled)
    expect(page).not_to have_text(notice_text)

    check "Auto-balance weights based on usage quotas"

    expect(weight_inputs).to all(be_disabled)
    expect(page).to have_text(notice_text)
  end
end
