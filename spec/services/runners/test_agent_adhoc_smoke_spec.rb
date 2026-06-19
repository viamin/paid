# frozen_string_literal: true

require "rails_helper"
require "securerandom"

# Drives an ad-hoc provider/model smoke test for bin/provider-smoke. Builds a
# direct-outbound runner for the PAID_SMOKE_ADHOC_* provider/model and runs the
# real agent-harness smoke contract in a container, so an unresolvable model id
# surfaces as a "Model not found" / ProviderModelNotFoundError failure here
# rather than at live agent-run time.
#
# Set PAID_SMOKE_ADHOC_DIAGNOSTIC=true (bin/provider-smoke -v) to run a
# diagnostic prompt instead of the fixed "OK" smoke contract: it passes on any
# clean model response and echoes the actual output/error, which is what you
# need to tell "model resolved but was chatty" apart from "model not found".
RSpec.describe Runners::TestAgent, :provider_smoke do
  scenarios = [ RunnerSmokeHelpers.adhoc_scenario_from_env ].compact

  if scenarios.empty?
    it "needs an ad-hoc provider/model" do
      skip "Set PAID_SMOKE_ADHOC_PROVIDER and PAID_SMOKE_ADHOC_MODEL (use bin/provider-smoke)"
    end
  end

  scenarios.each do |scenario|
    it "resolves and smoke-tests #{scenario.label}" do
      runner = build_adhoc_runner(scenario)
      result = run_adhoc_smoke(runner)
      report(scenario, result)

      expect(result).to be_success,
        "#{scenario.name} smoke test failed: #{result.error_type} - #{result.message}"
    rescue RunnerSmokeHelpers::ScenarioUnavailableError => e
      skip e.message
    end
  end

  def build_adhoc_runner(scenario)
    suffix = SecureRandom.hex(6)
    account = create(:account, slug: "provider-smoke-adhoc-#{suffix}")
    user = create(:user, :owner, account: account, email: "provider-smoke-adhoc-#{suffix}@example.com")
    RunnerSmokeHelpers.create_smoke_project!(user: user)
    RunnerSmokeHelpers.build_runner!(user: user, scenario: scenario)
  end

  def run_adhoc_smoke(runner)
    return Runners::TestAgent.call(runner: runner) unless ENV["PAID_SMOKE_ADHOC_DIAGNOSTIC"] == "true"

    # Pattern /\S/ ("any non-whitespace") passes on any real model response but
    # fails on empty output, so a model that resolves and answers is
    # distinguished from one that exits cleanly with nothing (a silent failure).
    # The Result message carries the real output/error for inspection.
    Runners::TestAgent.call(
      runner: runner,
      diagnostic_prompt: "Reply with exactly OK.",
      diagnostic_timeout: 60,
      diagnostic_success_pattern: /\S/
    )
  end

  def report(scenario, result)
    RSpec.configuration.reporter.message(
      "\n[provider-smoke] #{scenario.name}: success=#{result.success?} " \
      "error_type=#{result.error_type.inspect}\n[provider-smoke] message: #{result.message}\n"
    )
  end
end
