# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureFlags do
  # @spec MAINT-001
  it "defines maintenance_runs default-off" do
    project = create(:project)

    expect(described_class::DEFINITIONS).to include(:maintenance_runs)
    expect(described_class.enabled?(:maintenance_runs, project:)).to be(false)
  end

  # @spec MAINT-001
  it "allows tenant opt-in through tenant_settings.features" do
    account = create(:account)
    account.create_tenant_setting!(features: { "maintenance_runs" => true })
    opted_in_project = create(:project, account:)
    other_project = create(:project)

    expect(described_class.enabled?(:maintenance_runs, project: opted_in_project)).to be(true)
    expect(described_class.enabled?(:maintenance_runs, project: other_project)).to be(false)
  end
end
