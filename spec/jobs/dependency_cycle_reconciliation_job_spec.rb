# frozen_string_literal: true

require "rails_helper"

RSpec.describe DependencyCycleReconciliationJob do
  let(:baseline_account_id) { Account.maximum(:id).to_i }

  before do
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "covers every account in a bounded cycle through durable continuations without duplicate work" do
    baseline = baseline_account_id
    stub_const("DependencyCycleReconciliationJob::PAGE_SIZE", 1)
    first_account = create(:account)
    second_account = create(:account)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::DependencyCycles).to receive(:call) { |account:| calls << account.id; [] }

    described_class.perform_now(after_account_id: baseline)

    expect(calls).to eq([ first_account.id ])
    expect(continuations).to contain_exactly(after_account_id: first_account.id, through_account_id: second_account.id)

    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ first_account.id, second_account.id ])
  end

  # @spec AUTO-PICK-QUEUE-014
  it "bumps the dashboard cache version only after a successful reconciliation" do
    baseline = baseline_account_id
    account = create(:account)
    allow(Issues::DependencyCycles).to receive(:call).and_return([])
    allow(Dashboard::CacheVersion).to receive(:bump)

    described_class.perform_now(after_account_id: baseline)

    expect(Dashboard::CacheVersion).to have_received(:bump).with(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "does not bump the dashboard cache version when reconciliation reports coverage unavailable" do
    baseline = baseline_account_id
    create(:account)
    allow(Issues::DependencyCycles).to receive(:call).and_raise(Issues::DependencyCycles::CoverageUnavailable, "boom")
    allow(Dashboard::CacheVersion).to receive(:bump)

    described_class.perform_now(after_account_id: baseline)

    expect(Dashboard::CacheVersion).not_to have_received(:bump)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "retries a failed account from its own cursor while continuing other accounts in the page" do
    baseline = baseline_account_id
    stub_const("DependencyCycleReconciliationJob::PAGE_SIZE", 2)
    failing_account = create(:account)
    healthy_account = create(:account)
    continuations = []
    calls = []
    attempts = 0
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Dashboard::CacheVersion).to receive(:bump)
    allow(Issues::DependencyCycles).to receive(:call) do |account:|
      calls << account.id
      raise Issues::DependencyCycles::CoverageUnavailable, "unavailable" if account == failing_account && (attempts += 1) == 1

      []
    end

    described_class.perform_now(after_account_id: baseline)

    expect(calls).to eq([ failing_account.id, healthy_account.id ])
    expect(continuations.first.fetch(:pending_accounts)).to include(
      failing_account.id.to_s => hash_including(account_id: failing_account.id, attempts: 1)
    )
    expect(Dashboard::CacheVersion).to have_received(:bump).with(healthy_account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    expect(Dashboard::CacheVersion).not_to have_received(:bump).with(failing_account, scope: anything)

    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ failing_account.id, healthy_account.id, failing_account.id ])
    expect(Dashboard::CacheVersion).to have_received(:bump).with(failing_account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "defers a persistently failing account after one retry and advances the cycle" do
    baseline = baseline_account_id
    stub_const("DependencyCycleReconciliationJob::PAGE_SIZE", 2)
    failing_account = create(:account)
    healthy_account = create(:account)
    later_account = create(:account)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::DependencyCycles).to receive(:call) do |account:|
      calls << account.id
      raise "db unavailable" if account == failing_account

      []
    end

    described_class.perform_now(after_account_id: baseline)
    described_class.perform_now(**continuations.shift)
    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ failing_account.id, healthy_account.id, failing_account.id, later_account.id ])
    expect(continuations).to be_empty
  end

  # @spec AUTO-PICK-QUEUE-014
  it "defers an account created mid-cycle to a later cycle" do
    baseline = baseline_account_id
    stub_const("DependencyCycleReconciliationJob::PAGE_SIZE", 1)
    first_account = create(:account)
    second_account = create(:account)
    continuations = []
    calls = []
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Issues::DependencyCycles).to receive(:call) { |account:| calls << account.id; [] }

    described_class.perform_now(after_account_id: baseline)
    added_during_cycle = create(:account)
    described_class.perform_now(**continuations.shift)

    expect(calls).to eq([ first_account.id, second_account.id ])
    expect(calls).not_to include(added_during_cycle.id)
    expect(continuations).to be_empty
    expect(first_account.id).to be < second_account.id

    described_class.perform_now(after_account_id: baseline)
    described_class.perform_now(**continuations.shift) while continuations.any?

    expect(calls).to include(added_during_cycle.id)
  end

  # @spec AUTO-PICK-QUEUE-014
  it "logs account counts, duration, and allocations for each page" do
    baseline = baseline_account_id
    create(:account)
    allow(Issues::DependencyCycles).to receive(:call).and_return([])

    described_class.perform_now(after_account_id: baseline)

    expect(Rails.logger).to have_received(:info).with(
      hash_including(
        message: "dependency_cycle_reconciliation.page_completed",
        account_count: 1,
        succeeded_count: 1,
        failed_count: 0,
        duration_ms: kind_of(Integer),
        allocations: kind_of(Integer)
      )
    )
  end

  # @spec AUTO-PICK-QUEUE-014
  it "does nothing when there are no new accounts past the cursor" do
    baseline = baseline_account_id

    expect { described_class.perform_now(after_account_id: baseline) }.not_to raise_error
  end
end
