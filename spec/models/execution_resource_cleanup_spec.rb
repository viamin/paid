# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-036
RSpec.describe ExecutionResourceCleanup do
  describe "associations" do
    it { is_expected.to belong_to(:account).optional(true) }
    it { is_expected.to belong_to(:project).optional(true) }
    it { is_expected.to belong_to(:agent_run).optional(true) }
    it { is_expected.to belong_to(:provisioning_intent).optional(true) }
  end

  describe "validations" do
    subject(:cleanup) { build(:execution_resource_cleanup) }

    it { is_expected.to validate_presence_of(:runner_type) }
    it { is_expected.to validate_presence_of(:resource_kind) }
    it { is_expected.to validate_presence_of(:provider_resource_id) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_presence_of(:next_attempt_at) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_numericality_of(:attempts).is_greater_than_or_equal_to(0) }
  end

  describe ".due" do
    it "returns pending rows whose retry window has opened" do
      due_cleanup = create(:execution_resource_cleanup, next_attempt_at: 1.minute.ago)
      create(:execution_resource_cleanup, next_attempt_at: 5.minutes.from_now)
      create(:execution_resource_cleanup, :completed)

      expect(described_class.due).to contain_exactly(due_cleanup)
    end
  end

  describe "#record_failure!" do
    it "increments attempts and pushes the next retry out" do
      cleanup = create(:execution_resource_cleanup)

      freeze_time do
        cleanup.record_failure!(error: "provider timeout", next_attempt_at: 5.minutes.from_now)

        expect(cleanup.reload.attempts).to eq(1)
        expect(cleanup.last_error).to eq("provider timeout")
        expect(cleanup.next_attempt_at).to eq(5.minutes.from_now)
      end
    end
  end

  describe "#mark_completed!" do
    it "marks the row completed idempotently" do
      cleanup = create(:execution_resource_cleanup)

      cleanup.mark_completed!
      completed_at = cleanup.reload.completed_at
      cleanup.mark_completed!

      expect(cleanup.reload.status).to eq("completed")
      expect(cleanup.completed_at).to eq(completed_at)
    end
  end
end
