# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-001
RSpec.describe PostDeployMeasurements::Registry do
  it "contains only code-reviewed allowlisted checks" do
    expect(described_class.all.map(&:key)).to eq(%w[planning_hold_notifications_actionable])
  end

  it "finds a check by key" do
    check = described_class.find("planning_hold_notifications_actionable")

    expect(check.version).to eq(1)
    expect(check.measurer).to respond_to(:measure)
  end

  it "rejects unknown keys" do
    expect { described_class.find!("operator_supplied_sql") }
      .to raise_error(described_class::UnknownCheck, /not allowlisted/)
  end

  it "rejects string keys that do not match" do
    expect(described_class.find("'; DROP TABLE notifications;")).to be_nil
  end
end
