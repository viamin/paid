# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Runners::TestAgent, :provider_smoke do
  RunnerSmokeHelpers.scenarios_from_env.each do |scenario|
    it "passes the real smoke test for #{scenario.label}" do
      unique_suffix = SecureRandom.hex(6)
      account = create(:account, slug: "provider-smoke-local-#{unique_suffix}")
      user = create(:user, :owner, account: account, email: "provider-smoke-local-#{unique_suffix}@example.com")
      RunnerSmokeHelpers.create_smoke_project!(user: user)
      runner = RunnerSmokeHelpers.build_runner!(user: user, scenario: scenario)

      result =
        if scenario.diagnostic?
          described_class.call(
            runner: runner,
            diagnostic_prompt: scenario.diagnostic_prompt,
            diagnostic_timeout: scenario.diagnostic_timeout,
            diagnostic_success_pattern: scenario.diagnostic_success_pattern
          )
        else
          described_class.call(runner: runner)
        end

      expect(result).to be_success, "#{scenario.name} smoke test failed: #{result.error_type} - #{result.message}"
    rescue RunnerSmokeHelpers::ScenarioUnavailableError => e
      skip e.message
    end
  end
end
