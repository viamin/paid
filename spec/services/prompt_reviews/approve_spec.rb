# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptReviews::Approve do
  let(:account) { create(:account) }
  let(:reviewer) { create(:user, account: account) }
  let(:prompt) { create(:prompt, :for_account, :requires_review, :with_version, account: account) }
  let(:pending_version) do
    prompt.create_pending_version!(template: "Proposed variant {{title}}", change_notes: "Evolved")
  end

  describe ".call" do
    it "marks the version approved and promotes it to current" do
      original = prompt.current_version

      described_class.call(prompt_version: pending_version, reviewer: reviewer, notes: "LGTM")

      pending_version.reload
      expect(pending_version).to be_approved
      expect(pending_version.reviewed_by_user).to eq(reviewer)
      expect(pending_version.reviewed_at).to be_present
      expect(pending_version.review_notes).to eq("LGTM")
      expect(prompt.reload.current_version).to eq(pending_version)
      expect(prompt.reload.current_version).not_to eq(original)
    end

    it "can approve without promoting when promote: false" do
      original = prompt.current_version

      described_class.call(prompt_version: pending_version, reviewer: reviewer, promote: false)

      expect(pending_version.reload).to be_approved
      expect(prompt.reload.current_version).to eq(original)
    end

    it "raises when version is not pending" do
      pending_version.update!(review_status: "approved")

      expect {
        described_class.call(prompt_version: pending_version, reviewer: reviewer)
      }.to raise_error(ArgumentError, /not pending/)
    end

    it "raises without a reviewer" do
      expect {
        described_class.call(prompt_version: pending_version, reviewer: nil)
      }.to raise_error(ArgumentError, /reviewer/)
    end
  end
end
