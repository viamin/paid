# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::InfrastructureSpend do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before { allow(Rails.logger).to receive(:warn) }

  def spent_cents_for_account
    described_class.spent_cents(
      account: account,
      starts_at: Time.utc(2026, 8, 23, 0, 0, 0),
      ends_at: Time.utc(2026, 8, 24, 0, 0, 0)
    )
  end

  def create_costed_run(external_metadata:)
    create(
      :agent_run,
      :completed,
      project: project,
      provisioning_started_at: Time.utc(2026, 8, 23, 12, 0, 0),
      started_at: Time.utc(2026, 8, 23, 12, 0, 0),
      completed_at: Time.utc(2026, 8, 23, 13, 0, 0),
      container_host: "local",
      external_metadata: external_metadata
    )
  end

  def create_overlap_run(status:, provisioning_started_at:, completed_at: nil, rate_cents_per_hour:)
    create(
      :agent_run,
      status,
      project: project,
      provisioning_started_at: provisioning_started_at,
      started_at: provisioning_started_at,
      completed_at: completed_at,
      container_host: "local",
      external_metadata: { "infrastructure_spend" => { "rate_cents_per_hour" => rate_cents_per_hour } }
    )
  end

  def sql_aggregation_service
    described_class.new(
      account: account,
      starts_at: Time.utc(2026, 8, 23, 12, 0, 0),
      ends_at: Time.utc(2026, 8, 24, 0, 0, 0)
    )
  end

  # @spec INFRA-SPEND-001
  it "costs a run using the rate stamped into external_metadata at admission time" do
    create_costed_run(external_metadata: { "infrastructure_spend" => { "rate_cents_per_hour" => 200 } })

    expect(spent_cents_for_account).to eq(200)
    expect(Rails.logger).not_to have_received(:warn)
  end

  # @spec INFRA-SPEND-001
  it "treats a run without a stamped rate as uncosted instead of falling back to live config" do
    run = create_costed_run(external_metadata: {})
    allow(Capacity::InfrastructureLimits).to receive(:rate_cents_per_hour).and_return(500)

    expect(spent_cents_for_account).to eq(0)
    expect(Capacity::InfrastructureLimits).not_to have_received(:rate_cents_per_hour)
    expect(Rails.logger).to have_received(:warn).with(
      hash_including(message: "capacity.infrastructure_spend_rate_missing", agent_run_id: run.id, container_host: "local")
    )
  end

  # @spec INFRA-SPEND-001
  it "excludes runs completed well before the queried window" do
    create(
      :agent_run,
      :completed,
      project: project,
      provisioning_started_at: Time.utc(2026, 8, 1, 12, 0, 0),
      started_at: Time.utc(2026, 8, 1, 12, 0, 0),
      completed_at: Time.utc(2026, 8, 1, 13, 0, 0),
      container_host: "local",
      external_metadata: { "infrastructure_spend" => { "rate_cents_per_hour" => 200 } }
    )

    expect(spent_cents_for_account).to eq(0)
  end

  # @spec INFRA-SPEND-001
  it "aggregates overlapping run spend in SQL without materializing the relation" do
    create_overlap_run(
      status: :completed,
      provisioning_started_at: Time.utc(2026, 8, 23, 11, 30, 0),
      completed_at: Time.utc(2026, 8, 23, 12, 15, 0),
      rate_cents_per_hour: 120
    )
    create_overlap_run(
      status: :running,
      provisioning_started_at: Time.utc(2026, 8, 23, 23, 30, 0),
      rate_cents_per_hour: 240
    )
    service = sql_aggregation_service

    expect(service.send(:overlapping_runs)).not_to receive(:to_a)
    expect(service.spent_cents).to eq(150)
  end
end
