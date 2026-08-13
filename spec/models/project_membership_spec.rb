# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectMembership do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    subject { build(:project_membership) }

    it { is_expected.to validate_uniqueness_of(:user_id).scoped_to(:project_id).with_message("already has a membership in this project") }

    it "validates role inclusion" do
      membership = build(:project_membership, role: :admin)
      expect(membership).to be_valid
    end

    it "rejects invalid roles via validation" do
      membership = build(:project_membership)
      membership.role = "invalid_role"
      expect(membership).not_to be_valid
      expect(membership.errors[:role]).to be_present
    end
  end

  describe "roles" do
    it "defines viewer, member, and admin roles" do
      expect(described_class.roles.keys).to match_array(%w[viewer member admin])
    end

    it "has correct role values for hierarchy" do
      expect(described_class.roles["viewer"]).to eq(0)
      expect(described_class.roles["member"]).to eq(1)
      expect(described_class.roles["admin"]).to eq(2)
    end
  end

  describe "#permission_level" do
    it "returns the numeric value of the role" do
      membership = build(:project_membership, role: :admin)
      expect(membership.permission_level).to eq(2)
    end
  end

  describe "#at_least?" do
    let(:membership) { build(:project_membership, role: :member) }

    it "returns true for roles at or below current level" do
      expect(membership.at_least?(:viewer)).to be true
      expect(membership.at_least?(:member)).to be true
    end

    it "returns false for roles above current level" do
      expect(membership.at_least?(:admin)).to be false
    end
  end

  describe "role predicate methods" do
    it "provides predicate methods for each role" do
      admin = build(:project_membership, role: :admin)
      member = build(:project_membership, role: :member)
      viewer = build(:project_membership, role: :viewer)

      expect(admin.admin?).to be true
      expect(admin.member?).to be false

      expect(member.member?).to be true
      expect(member.viewer?).to be false

      expect(viewer.viewer?).to be true
      expect(viewer.admin?).to be false
    end
  end
end
