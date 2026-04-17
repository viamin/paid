# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptReviews::Edit do
  let(:account) { create(:account) }
  let(:reviewer) { create(:user, account: account) }
  let(:prompt) { create(:prompt, :for_account, :requires_review, :with_version, account: account) }
  let!(:pending_version) do
    prompt.create_pending_version!(template: "Original proposed {{title}}", change_notes: "Evolved")
  end

  describe ".call" do
    it "creates a new pending version with the edited template" do
      expect {
        described_class.call(
          prompt_version: pending_version,
          reviewer: reviewer,
          attributes: { template: "Refined proposal {{title}}", change_notes: "Tightened wording" }
        )
      }.to change(PromptVersion, :count).by(1)

      new_version = prompt.reload.prompt_versions.order(:version).last
      expect(new_version.template).to eq("Refined proposal {{title}}")
      expect(new_version).to be_pending_review
      expect(new_version.parent_version).to eq(pending_version)
      expect(new_version.created_by_user).to eq(reviewer)
    end

    it "supersedes the old version as rejected" do
      described_class.call(
        prompt_version: pending_version,
        reviewer: reviewer,
        attributes: { template: "Refined proposal {{title}}" }
      )

      expect(pending_version.reload).to be_rejected
      expect(pending_version.review_notes).to include("Superseded")
      expect(pending_version.reviewed_by_user).to eq(reviewer)
    end

    it "does not promote anything to current_version" do
      original_current = prompt.current_version

      described_class.call(
        prompt_version: pending_version,
        reviewer: reviewer,
        attributes: { template: "Refined {{title}}" }
      )

      expect(prompt.reload.current_version).to eq(original_current)
    end

    it "requires a non-empty template" do
      expect {
        described_class.call(prompt_version: pending_version, reviewer: reviewer, attributes: { template: "" })
      }.to raise_error(ArgumentError, /template/)
    end

    it "rejects editing non-pending versions" do
      pending_version.update!(review_status: "approved")

      expect {
        described_class.call(prompt_version: pending_version, reviewer: reviewer, attributes: { template: "x" })
      }.to raise_error(ArgumentError, /not pending/)
    end
  end
end
