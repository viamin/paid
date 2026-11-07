# frozen_string_literal: true

require "rails_helper"

RSpec.describe DependencyCycleReconciliationJob do
  let(:reconciled_account_ids) { [] }
  let(:continuations) { [] }

  before do
    allow(described_class).to receive(:perform_later) { |**arguments| continuations << arguments }
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
  end

  # The sweep reconciles the whole account fleet, so every expectation is
  # expressed over the accounts present when the cycle starts. The fleet can
  # already carry a seeded account.
  def fleet_account_ids
    Account.order(:id).pluck(:id)
  end

  # Records which accounts the sweep reconciles, and lets the example decide
  # whether a given account fails.
  def stub_reconciliation(&failure)
    allow(Issues::DependencyCycles).to receive(:call) do |account:, **|
      reconciled_account_ids << account.id
      failure&.call(account)
      []
    end
  end

  # Drives the cycle the cron tick starts: every queued continuation runs
  # until the cycle reaches its captured end.
  def drive_cycle
    described_class.perform_now
    drive_continuations
  end

  def drive_continuations
    while (continuation = continuations.shift)
      described_class.perform_now(**continuation)
    end
  end

  describe "GoodJob concurrency" do
    it "runs on the maintenance queue with a single performing page" do
      config = described_class.good_job_concurrency_config

      expect(described_class.queue_name).to eq("maintenance")
      expect(config).to include(enqueue_limit: 2, perform_limit: 1)
      expect(config[:key]).to eq("dependency_cycle_reconciliation")
    end
  end

  describe "#perform" do
    # @spec AUTO-PICK-QUEUE-023
    it "reconciles every account of the fleet exactly once across a cycle's pages" do
      stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 2)
      Array.new(3) { create(:account) }
      fleet = fleet_account_ids
      stub_reconciliation

      drive_cycle

      expect(reconciled_account_ids).to eq(fleet)
      expect(reconciled_account_ids.uniq.size).to eq(fleet.size)
      expect(continuations).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-023
    it "hands the next page the reconciled cursor and the cycle's captured end" do
      stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 1)
      Array.new(2) { create(:account) }
      fleet = fleet_account_ids
      stub_reconciliation

      described_class.perform_now

      expect(continuations).to contain_exactly(
        after_account_id: fleet.first, through_account_id: fleet.last, attempts: 0
      )
    end

    # @spec AUTO-PICK-QUEUE-023
    it "retries a failed account before the cycle advances past it" do
      stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 2)
      Array.new(2) { create(:account) }
      fleet = fleet_account_ids
      failing = fleet.first
      attempts = 0
      stub_reconciliation do |account|
        attempts += 1 if account.id == failing
        raise "dependency graph unavailable" if account.id == failing && attempts == 1
      end

      described_class.perform_now
      described_class.perform_now(**continuations.shift)
      drive_continuations

      expect(reconciled_account_ids).to eq([ failing, failing ] + fleet.drop(1))
    end

    # @spec AUTO-PICK-QUEUE-023
    it "moves past an account whose retries are exhausted" do
      stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 2)
      Array.new(2) { create(:account) }
      fleet = fleet_account_ids
      failing = fleet.first
      stub_reconciliation do |account|
        raise "dependency graph unavailable" if account.id == failing
      end

      described_class.perform_now
      2.times do
        described_class.perform_now(**continuations.shift)
      end
      drive_continuations

      expect(reconciled_account_ids).to eq([ failing, failing, failing ] + fleet.drop(1))
      expect(continuations).to be_empty
      expect(Rails.logger).to have_received(:error).with(
        hash_including(message: "dependency_cycles.reconciliation_retries_exhausted", account_id: failing)
      )
    end

    # @spec AUTO-PICK-QUEUE-023
    it "reconciles an account created during a cycle in a later cycle" do
      stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 2)
      existing = create(:account)
      stub_reconciliation
      first_cycle = fleet_account_ids

      described_class.perform_now
      drive_continuations

      expect(reconciled_account_ids).to eq(first_cycle)

      added = create(:account)
      second_cycle = fleet_account_ids
      described_class.perform_now
      drive_continuations

      expect(reconciled_account_ids).to eq(first_cycle + second_cycle)
      expect(added.id).to be > existing.id
    end

    # @spec AUTO-PICK-QUEUE-023
    it "invalidates the dashboard cache only after a successful reconciliation" do
      account = create(:account)
      stub_reconciliation
      allow(Dashboard::CacheVersion).to receive(:bump)

      described_class.perform_now

      expect(Dashboard::CacheVersion).to have_received(:bump).with(
        account, scope: Dashboard::CacheVersion::LISTS_SCOPE
      )
    end

    # @spec AUTO-PICK-QUEUE-023
    it "reports an unavailable reconciliation without invalidating the dashboard cache" do
      account = create(:account)
      allow(Issues::DependencyCycles).to receive(:call).and_raise(
        Issues::DependencyCycles::CoverageUnavailable, "dependency graph unavailable"
      )
      allow(Dashboard::CacheVersion).to receive(:bump)

      described_class.perform_now

      expect(Dashboard::CacheVersion).not_to have_received(:bump)
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "dependency_cycles.reconciliation_unavailable", account_id: account.id)
      )
    end

    # @spec AUTO-PICK-QUEUE-023
    it "records the page duration and allocation cost" do
      create(:account)
      stub_reconciliation

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(
        hash_including(
          message: "dependency_cycles.reconciliation_page_completed",
          account_count: a_value >= 1,
          reconciled_count: a_value >= 1,
          duration_ms: a_kind_of(Integer),
          allocations: a_kind_of(Integer)
        )
      )
    end
  end

  describe "cycle admission", :good_job do
    around do |example|
      original_adapter = described_class.queue_adapter
      described_class.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      example.run
    ensure
      described_class.queue_adapter = original_adapter
      GoodJob::Job.where(job_class: described_class.name).delete_all
    end

    # @spec AUTO-PICK-QUEUE-023
    it "does not open a second cycle while the running cycle's next page is queued" do
      create(:account)
      stub_reconciliation
      allow(described_class).to receive(:perform_later).and_call_original
      described_class.perform_later(after_account_id: 1, through_account_id: 2, attempts: 0)

      described_class.perform_now

      expect(reconciled_account_ids).to be_empty
      expect(continuations).to be_empty
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "dependency_cycles.reconciliation_cycle_in_flight")
      )
    end

    # @spec AUTO-PICK-QUEUE-023
    it "persists and runs the cursor-carrying continuation" do
      stub_const("DependencyCycleReconciliationJob::ACCOUNT_PAGE_SIZE", 1)
      Array.new(2) { create(:account) }
      fleet = fleet_account_ids
      stub_reconciliation
      allow(described_class).to receive(:perform_later).and_call_original

      parent = described_class.perform_later
      GoodJob::Job.find(parent.provider_job_id).perform(lock_id: SecureRandom.uuid)

      5.times do
        continuation = GoodJob::Job.where(job_class: described_class.name, finished_at: nil).order(:id).first
        break unless continuation

        continuation.perform(lock_id: SecureRandom.uuid)
      end

      expect(reconciled_account_ids).to eq(fleet)
    end
  end
end
