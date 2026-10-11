# frozen_string_literal: true

require "rails_helper"

RSpec.describe LegacyPartialCloseoutReconciliationSweepJob do
  let(:account) { create(:account) }

  describe "GoodJob concurrency" do
    it "runs on maintenance with one fleet-wide scheduler invocation" do
      config = described_class.good_job_concurrency_config

      expect(described_class.queue_name).to eq("maintenance")
      # A cron invocation can arrive while a batch is performing. Reserve a
      # second queued position so that invocation cannot evict the batch's
      # cursor-carrying continuation.
      expect(config).to include(total_limit: 1, enqueue_limit: 2)
      expect(config[:key]).to eq("legacy_partial_closeout_reconciliation_sweep")
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

    def result_for(scanned: 0, reconciled: 0, awaiting_operator: 0, retryable_failure: 0, skipped: 0, next_cursor: nil, lock_held: false)
      PartialCloseouts::ReconcileLegacy::Result.new(
        scanned:, reconciled:, awaiting_operator:, retryable_failure:, skipped:, next_cursor:, lock_held:
      )
    end
  end
end
