# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Queue do
  # @spec APPLE-ATTEMPT-003

  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }
  let(:project_a) { create(:project, account: account_a) }
  let(:project_b) { create(:project, account: account_b) }

  describe ".ordered" do
    it "gives each account a turn before scheduling a second attempt" do
      older = create(:apple_verification_attempt, account: account_a, project: project_a, created_at: 3.days.ago)
      newer = create(:apple_verification_attempt, account: account_a, project: project_a, created_at: 1.day.ago)
      other_account = create(:apple_verification_attempt, account: account_b, project: project_b, created_at: 2.days.ago)

      expect(described_class.ordered).to eq([ older, other_account, newer ])
    end

    it "gives each project within an account a turn before scheduling a second attempt" do
      project_c = create(:project, account: account_a)
      first_project_first = create(:apple_verification_attempt, account: account_a, project: project_a, created_at: 3.days.ago)
      first_project_second = create(:apple_verification_attempt, account: account_a, project: project_a, created_at: 1.day.ago)
      second_project = create(:apple_verification_attempt, account: account_a, project: project_c, created_at: 2.days.ago)

      expect(described_class.ordered).to eq([ first_project_first, second_project, first_project_second ])
    end

    it "excludes non-queued attempts" do
      queued = create(:apple_verification_attempt, account: account_a, project: project_a)
      create(:apple_verification_attempt, :succeeded, account: account_a, project: project_a)
      create(:apple_verification_attempt, account: account_a, project: project_a, status: "running")

      expect(described_class.ordered).to eq([ queued ])
    end
  end

  describe ".position" do
    it "returns 1 for the first queued attempt and the correct rank for later ones" do
      first = create(:apple_verification_attempt, account: account_a, project: project_a)
      second = create(:apple_verification_attempt, account: account_a, project: project_a)
      third = create(:apple_verification_attempt, account: account_a, project: project_a)

      expect(described_class.position(attempt: first)).to eq(1)
      expect(described_class.position(attempt: second)).to eq(2)
      expect(described_class.position(attempt: third)).to eq(3)
    end

    it "returns nil for non-queued attempts" do
      running = create(:apple_verification_attempt, account: account_a, project: project_a, status: "running")
      succeeded = create(:apple_verification_attempt, :succeeded, account: account_a, project: project_a)

      expect(described_class.position(attempt: running)).to be_nil
      expect(described_class.position(attempt: succeeded)).to be_nil
    end
  end

  describe ".depth" do
    it "counts queued attempts only" do
      create(:apple_verification_attempt, account: account_a, project: project_a)
      create(:apple_verification_attempt, account: account_a, project: project_a)
      create(:apple_verification_attempt, :failed, account: account_a, project: project_a)
      create(:apple_verification_attempt, account: account_b, project: project_b, status: "provisioning")

      expect(described_class.depth).to eq(2)
    end
  end

  describe ".full?" do
    it "is true when depth reaches Config.max_queue_depth" do
      allow(AppleVerificationAttempts::Config).to receive(:max_queue_depth).and_return(2)

      expect(described_class.full?).to be(false)

      create(:apple_verification_attempt, account: account_a, project: project_a)
      create(:apple_verification_attempt, account: account_a, project: project_a)

      expect(described_class.full?).to be(true)
    end
  end

  describe "cancelling a queued attempt" do
    it "moves it out of the queue" do
      queued = create(:apple_verification_attempt, account: account_a, project: project_a)
      expect(described_class.depth).to eq(1)

      AppleVerificationAttempts::Cancel.call(attempt: queued)

      expect(queued.reload.status).to eq("cancelled")
      expect(described_class.depth).to eq(0)
      expect(described_class.position(attempt: queued)).to be_nil
    end
  end
end
