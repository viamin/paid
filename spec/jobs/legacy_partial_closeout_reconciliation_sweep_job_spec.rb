# frozen_string_literal: true

require "rails_helper"

RSpec.describe LegacyPartialCloseoutReconciliationSweepJob do
  let(:account) { create(:account) }

  def result_for(scanned: 0, reconciled: 0, awaiting_operator: 0, retryable_failure: 0, skipped: 0, next_cursor: nil, lock_held: false)
    PartialCloseouts::ReconcileLegacy::Result.new(
      scanned:, reconciled:, awaiting_operator:, retryable_failure:, skipped:, next_cursor:, lock_held:
    )
  end

  describe "GoodJob concurrency" do
    it "runs on maintenance with one fleet-wide scheduler invocation" do
      config = described_class.good_job_concurrency_config

      expect(described_class.queue_name).to eq("maintenance")
      expect(config).to include(enqueue_limit: 2, perform_limit: 1)
      expect(config).not_to have_key(:total_limit)
      expect(config[:key]).to eq("legacy_partial_closeout_reconciliation_sweep")
    end
  end

  describe "full batches", :good_job do
    around do |example|
      original_adapter = described_class.queue_adapter
      described_class.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      example.run
    ensure
      described_class.queue_adapter = original_adapter
      GoodJob::Job.where(job_class: described_class.name).delete_all
    end

    # @spec PARTIAL-CLOSEOUT-025
    it "persists and runs the cursor-carrying continuation" do
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call).and_return(
        result_for(scanned: 200, next_cursor: 241),
        result_for(scanned: 1, next_cursor: 242)
      )

      parent = described_class.perform_later(account_id: account.id, after_id: 41)
      GoodJob::Job.find(parent.provider_job_id).perform(lock_id: SecureRandom.uuid)

      continuation = GoodJob::Job.where(job_class: described_class.name, finished_at: nil).sole
      continuation.perform(lock_id: SecureRandom.uuid)

      expect(PartialCloseouts::ReconcileLegacy).to have_received(:call).with(account_id: account.id, after_id: 241)
    end
  end

  describe "#perform" do
    before do
      allow(Rails.logger).to receive(:info)
      allow(described_class).to receive(:perform_later)
    end

    # @spec PARTIAL-CLOSEOUT-025
    it "resumes an account from its persisted GoodJob cursor and records the batch outcome" do
      result = result_for(scanned: 200, next_cursor: 241, reconciled: 2, awaiting_operator: 1)
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call).and_return(result)

      described_class.perform_now(account_id: account.id, after_id: 41)

      expect(PartialCloseouts::ReconcileLegacy).to have_received(:call).with(account_id: account.id, after_id: 41)
      expect(described_class).to have_received(:perform_later).with(
        account_id: account.id, after_id: 241, after_account_id: nil
      )
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "partial_closeouts.legacy_reconcile_sweep_completed", account_id: account.id, scanned: 200)
      )
    end

    # @spec PARTIAL-CLOSEOUT-025
    it "moves to the next account after the account backlog is exhausted" do
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call).and_return(result_for(scanned: 3, next_cursor: 244))

      described_class.perform_now(account_id: account.id, after_id: 241)

      expect(described_class).to have_received(:perform_later).with(after_account_id: account.id)
    end

    # @spec PARTIAL-CLOSEOUT-025
    it "starts with the first active account and persists its account cursor" do
      account
      later_account = create(:account)
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call).and_return(result_for)

      described_class.perform_now

      expect(PartialCloseouts::ReconcileLegacy).to have_received(:call).with(account_id: account.id, after_id: nil)
      expect(described_class).to have_received(:perform_later).with(after_account_id: account.id)
      expect(later_account).to be_present
    end

    # @spec PARTIAL-CLOSEOUT-025
    it "records advisory-lock contention without scheduling a duplicate" do
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call).and_return(result_for(lock_held: true, next_cursor: 41))

      described_class.perform_now(account_id: account.id, after_id: 41)

      expect(described_class).not_to have_received(:perform_later)
    end
  end
end
