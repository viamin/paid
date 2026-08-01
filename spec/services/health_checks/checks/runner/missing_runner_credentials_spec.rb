# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Runner::MissingRunnerCredentials do
  it "returns a finding when an api_key runner has no usable credentials" do
    runner = build(:runner, auth_type: "api_key", provider_api_key: nil, integration_credential: nil)

    expect(described_class.call(runner)).to contain_exactly(
      have_attributes(
        check: described_class.name,
        scope: :runner,
        severity: :error,
        message: "Runner #{runner.display_name} is configured for API key auth but has no usable credentials."
      )
    )
  end

  it "returns no findings when an api_key runner has a usable secret" do
    user = create(:user)
    api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
    runner = create(:runner, :api_key, user: user, provider_api_key: api_key)

    expect(described_class.call(runner)).to eq([])
  end
end
