# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventionRecommendation do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:dismissed_by).class_name("User").optional(true) }
    it { is_expected.to belong_to(:applied_by).class_name("User").optional(true) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:convention_key) }
    it { is_expected.to validate_length_of(:convention_key).is_at_most(100) }
    it { is_expected.to validate_presence_of(:action_type) }
    it { is_expected.to validate_inclusion_of(:action_type).in_array(%w[apply_in_paid open_pr apply_github_side manual_review]) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(%w[pending applied dismissed]) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(255) }
    it { is_expected.to validate_presence_of(:description) }

    context "when dismissed" do
      it "requires a dismissal reason" do
        rec = build(:project_convention_recommendation, status: "dismissed", dismissal_reason: nil)
        expect(rec).not_to be_valid
        expect(rec.errors[:dismissal_reason]).to include("can't be blank")
      end
    end

    context "when pending" do
      it "does not require a dismissal reason" do
        rec = build(:project_convention_recommendation, status: "pending", dismissal_reason: nil)
        expect(rec).to be_valid
      end
    end
  end

  describe "scopes" do
    let(:project) { create(:project) }

    it "returns pending recommendations" do
      pending_rec = create(:project_convention_recommendation, project:, status: "pending")
      _applied_rec = create(:project_convention_recommendation, project:, status: "applied",
                             convention_key: "hook_manager", title: "Other")

      expect(described_class.pending).to include(pending_rec)
    end

    it "returns resolved recommendations" do
      _pending_rec = create(:project_convention_recommendation, project:, status: "pending")
      applied_rec = create(:project_convention_recommendation, project:, status: "applied",
                           convention_key: "hook_manager", title: "Other")
      dismissed_rec = create(:project_convention_recommendation, project:, status: "dismissed",
                             convention_key: "release_automation", title: "Third",
                             dismissal_reason: "Not needed")

      expect(described_class.resolved).to include(applied_rec, dismissed_rec)
    end
  end

  describe "#dismiss!" do
    let(:project) { create(:project) }
    let(:user) { create(:user, account: project.account) }
    let(:rec) { create(:project_convention_recommendation, project:) }

    it "updates status to dismissed" do
      rec.dismiss!(dismissed_by: user, reason: "Not relevant")
      expect(rec.reload.status).to eq("dismissed")
    end

    it "sets dismissed_at and dismissed_by" do
      rec.dismiss!(dismissed_by: user, reason: "Not relevant")
      expect(rec.dismissed_at).to be_present
      expect(rec.dismissed_by).to eq(user)
      expect(rec.dismissal_reason).to eq("Not relevant")
    end
  end

  describe "#apply!" do
    let(:project) { create(:project) }
    let(:user) { create(:user, account: project.account) }
    let(:rec) { create(:project_convention_recommendation, project:) }

    it "updates status to applied" do
      rec.apply!(applied_by: user)
      expect(rec.reload.status).to eq("applied")
    end

    it "sets applied_at and applied_by" do
      rec.apply!(applied_by: user)
      expect(rec.applied_at).to be_present
      expect(rec.applied_by).to eq(user)
    end
  end

  describe "#reopen!" do
    let(:project) { create(:project) }
    let(:rec) do
      create(:project_convention_recommendation, project:, status: "dismissed",
                                             dismissed_at: 1.hour.ago,
                                             dismissal_reason: described_class::AUTO_DISMISSAL_REASON)
    end

    it "returns an auto-dismissed recommendation to pending" do
      rec.reopen!(title: "Updated title")

      expect(rec.reload).to be_pending
      expect(rec.dismissed_at).to be_nil
      expect(rec.dismissal_reason).to be_nil
      expect(rec.title).to eq("Updated title")
    end
  end

  describe "#pending?, #dismissed?, #applied?, #resolved?" do
    let(:project) { create(:project) }

    it "returns correct state for pending" do
      rec = create(:project_convention_recommendation, project:, status: "pending")
      expect(rec).to be_pending
      expect(rec).not_to be_dismissed
      expect(rec).not_to be_applied
      expect(rec).not_to be_resolved
    end

    it "returns correct state for dismissed" do
      rec = create(:project_convention_recommendation, project:, status: "dismissed",
                   dismissal_reason: "No")
      expect(rec).not_to be_pending
      expect(rec).to be_dismissed
      expect(rec).not_to be_applied
      expect(rec).to be_resolved
    end

    it "returns correct state for applied" do
      rec = create(:project_convention_recommendation, project:, status: "applied")
      expect(rec).not_to be_pending
      expect(rec).not_to be_dismissed
      expect(rec).to be_applied
      expect(rec).to be_resolved
    end
  end

  describe "#auto_dismissed?" do
    let(:project) { create(:project) }

    it "returns true only for system dismissals caused by missing detections" do
      rec = create(:project_convention_recommendation, project:, status: "dismissed",
                                                     dismissal_reason: described_class::AUTO_DISMISSAL_REASON)
      expect(rec).to be_auto_dismissed
    end

    it "returns false for manual dismissals" do
      rec = create(:project_convention_recommendation, project:, status: "dismissed",
                                                     dismissal_reason: "Not relevant",
                                                     dismissed_by: create(:user, account: project.account))
      expect(rec).not_to be_auto_dismissed
    end
  end
end
