# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptReviews::Reject do
  let(:account) { create(:account) }
  let(:reviewer) { create(:user, account: account) }
  let(:prompt) { create(:prompt, :for_account, :requires_review, :with_version, account: account) }
  let(:pending_version) do
    prompt.create_pending_version!(template: "Proposed variant {{title}}")
  end

  describe ".call" do
    it "marks the version rejected with reviewer + notes" do
      described_class.call(prompt_version: pending_version, reviewer: reviewer, notes: "Changes safety wording")

      pending_version.reload
      expect(pending_version).to be_rejected
      expect(pending_version.reviewed_by_user).to eq(reviewer)
      expect(pending_version.review_notes).to eq("Changes safety wording")
    end

    it "does not change the prompt's current version" do
      original = prompt.current_version
      described_class.call(prompt_version: pending_version, reviewer: reviewer, notes: "nope")

      expect(prompt.reload.current_version).to eq(original)
    end

    it "requires non-empty notes" do
      expect {
        described_class.call(prompt_version: pending_version, reviewer: reviewer, notes: "   ")
      }.to raise_error(ArgumentError, /notes/)
    end

    it "raises when version is not pending" do
      pending_version.update!(review_status: "rejected")
      expect {
        described_class.call(prompt_version: pending_version, reviewer: reviewer, notes: "x")
      }.to raise_error(ArgumentError, /not pending/)
    end
  end
end
