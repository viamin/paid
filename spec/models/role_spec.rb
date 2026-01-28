# frozen_string_literal: true

require "rails_helper"

RSpec.describe Role do
  describe "associations" do
    it { is_expected.to have_and_belong_to_many(:users).join_table(:users_roles) }
    it { is_expected.to belong_to(:resource).optional }
  end

  describe "validations" do
    it "allows valid resource types" do
      account = create(:account)
      role = described_class.new(name: "owner", resource_type: "Account", resource_id: account.id)
      expect(role).to be_valid
    end

    it "allows nil resource type for global roles" do
      role = described_class.new(name: "admin", resource_type: nil)
      expect(role).to be_valid
    end
  end

  describe "scoping" do
    it "can be scoped to a resource" do
      account = create(:account)
      user = create(:user, account: account)
      user.add_role(:owner, account)

      role = user.roles.find_by(name: "owner")

      expect(role.resource_type).to eq("Account")
      expect(role.resource_id).to eq(account.id)
    end
  end
end
