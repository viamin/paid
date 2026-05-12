# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationPolicyVersion do
  subject(:coordination_policy_version) { build(:coordination_policy_version) }

  describe "associations" do
    it { is_expected.to belong_to(:coordination_policy).touch(true) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:version) }
    it { is_expected.to validate_numericality_of(:version).only_integer.is_greater_than(0) }
    it { is_expected.to validate_uniqueness_of(:version).scoped_to(:coordination_policy_id) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "requires rules to be a hash" do
      coordination_policy_version.rules = "invalid"

      expect(coordination_policy_version).not_to be_valid
      expect(coordination_policy_version.errors[:rules]).to include("must be a JSON object")
    end

    it "requires parameters to be a hash" do
      coordination_policy_version.parameters = []

      expect(coordination_policy_version).not_to be_valid
      expect(coordination_policy_version.errors[:parameters]).to include("must be a JSON object")
    end

    it "requires metadata to be a hash" do
      coordination_policy_version.metadata = []

      expect(coordination_policy_version).not_to be_valid
      expect(coordination_policy_version.errors[:metadata]).to include("must be a JSON object")
    end
  end

  describe "#activate!" do
    it "delegates activation to the owning policy" do
      policy = create(:coordination_policy)
      active_version = create(:coordination_policy_version, :active, coordination_policy: policy, version: 1)
      next_version = create(:coordination_policy_version, coordination_policy: policy, version: 2)

      policy.update!(current_version: active_version, status: "active")
      next_version.activate!

      expect(policy.reload.current_version).to eq(next_version)
      expect(active_version.reload.status).to eq("superseded")
      expect(next_version.reload.status).to eq("active")
    end
  end

  describe "review state" do
    it "treats versions without review metadata as activatable" do
      version = build(:coordination_policy_version, metadata: {})

      expect(version).to be_activatable
      expect(version).not_to be_review_required
    end

    it "requires approval when metadata marks the version pending review" do
      version = build(:coordination_policy_version, metadata: {
        "evolution" => {
          "approval" => {
            "required" => true,
            "status" => "pending_review"
          }
        }
      })

      expect(version).to be_review_required
      expect(version.review_status).to eq("pending_review")
      expect(version).not_to be_approved
      expect(version).not_to be_activatable
    end

    it "allows activation once the required review is approved" do
      version = build(:coordination_policy_version, metadata: {
        "evolution" => {
          "approval" => {
            "required" => true,
            "status" => "approved"
          }
        }
      })

      expect(version).to be_review_required
      expect(version).to be_approved
      expect(version).to be_activatable
    end
  end
end
