# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeIntents::RequestChanges do
  let(:project) { create(:project) }
  let(:change_intent) { create(:change_intent, :draft, project: project) }

  describe ".call" do
    # @spec CHANGE-INTENT-INBOX-001
    it "transitions the draft into requested_changes with the supplied reason" do
      result = nil
      travel_to(Time.current) do
        result = described_class.call(change_intent: change_intent, reason: "Reword the title.")
      end

      expect(result).to include(
        id: change_intent.id,
        project_id: project.id,
        status: "requested_changes",
        title: change_intent.title,
        requested_changes_reason: "Reword the title."
      )
      expect(result[:requested_changes_at]).to be_present
      expect(change_intent.reload).to have_attributes(
        status: "requested_changes",
        requested_changes_reason: "Reword the title."
      )
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "preserves the entry in the Inbox after stamping requested_changes" do
      described_class.call(change_intent: change_intent, reason: "Tighten the constraints.")

      expect(change_intent.reload).to be_requested_changes
      expect(change_intent).to be_pending_review
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "raises when the record is no longer in a pending-review state" do
      change_intent.update!(status: "active")

      expect { described_class.call(change_intent: change_intent, reason: "Too late.") }
        .to raise_error(ChangeIntent::InvalidTransitionError, /cannot request changes from active/)
    end

    # @spec CHANGE-INTENT-INBOX-001
    it "tolerates a blank reason so a quick review can still record feedback" do
      result = described_class.call(change_intent: change_intent, reason: "   ")

      expect(result[:requested_changes_reason]).to be_nil
      expect(change_intent.reload.requested_changes_reason).to be_nil
    end
  end
end
