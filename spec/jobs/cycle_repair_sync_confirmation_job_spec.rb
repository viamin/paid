# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleRepairSyncConfirmationJob do
  describe "#perform" do
    let(:account1) { create(:account) }
    let(:account2) { create(:account) }

    context "with pending repairs across multiple accounts" do
      before do
        create(:project, account: account1)
        create(:project, account: account2)
      end

      it "processes all accounts" do
        expect(CycleBreakers::ConfirmSync).to receive(:call).with(account: account1).and_return(
          CycleBreakers::ConfirmSync::Result.new(confirmed_count: 1, failed_count: 0, stale_count: 0)
        )
        expect(CycleBreakers::ConfirmSync).to receive(:call).with(account: account2).and_return(
          CycleBreakers::ConfirmSync::Result.new(confirmed_count: 0, failed_count: 0, stale_count: 1)
        )

        expect { CycleRepairSyncConfirmationJob.perform_now }.not_to raise_error
      end
    end

    context "with no pending repairs" do
      let(:account) { create(:account) }

      before { create(:project, account: account) }

      it "completes without error" do
        expect { CycleRepairSyncConfirmationJob.perform_now }.not_to raise_error
      end
    end

    context "when confirmation fails for an account" do
      let(:account1) { create(:account) }
      let(:account2) { create(:account) }

      before do
        create(:project, account: account1)
        create(:project, account: account2)
        allow(CycleBreakers::ConfirmSync).to receive(:call).with(account: account1)
          .and_raise(StandardError.new("DB error"))
        allow(CycleBreakers::ConfirmSync).to receive(:call).with(account: account2)
          .and_return(CycleBreakers::ConfirmSync::Result.new(confirmed_count: 1, failed_count: 0, stale_count: 0))
      end

      it "continues processing other accounts" do
        expect { CycleRepairSyncConfirmationJob.perform_now }.not_to raise_error
      end
    end

    context "concurrency control" do
      it "is configured as a maintenance job" do
        job = CycleRepairSyncConfirmationJob.new
        expect(job.class.queue_name).to eq "maintenance"
      end
    end
  end
end
