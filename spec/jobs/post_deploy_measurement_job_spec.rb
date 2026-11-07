# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-009
RSpec.describe PostDeployMeasurementJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:measurement) { create(:post_deploy_measurement, issue: issue, project: project) }

  it "executes the measurement under its own tenant context" do
    executed_with = nil
    allow(PostDeployMeasurements::Execute).to receive(:call) do |measurement:|
      executed_with = Current.account
      PostDeployMeasurements::Execute::Result.new(measurement: measurement, status: measurement.status)
    end

    described_class.new.perform(measurement.id)

    expect(executed_with&.id).to eq(account.id)
  end

  it "resolves the tenant account for failure notifications" do
    job = described_class.new(measurement.id)

    expect(job.send(:tenant_account)&.id).to eq(account.id)
  end

  it "discards when the measurement no longer exists" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end

  it "runs on the maintenance queue with serialized concurrency" do
    expect(described_class.queue_name).to eq("maintenance")
    expect(described_class.max_attempts).to eq(1)
  end
end
