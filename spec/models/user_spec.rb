# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
  end

  describe "validations" do
    subject { build(:user) }

    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }
    it { is_expected.to validate_presence_of(:account) }

    it "validates password length" do
      user = build(:user, password: "short", password_confirmation: "short")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to include("is too short (minimum is 6 characters)")
    end

    it "validates password confirmation" do
      user = build(:user, password: "password123", password_confirmation: "different")
      expect(user).not_to be_valid
      expect(user.errors[:password_confirmation]).to include("doesn't match Password")
    end
  end

  describe "devise modules" do
    it "is database authenticatable" do
      expect(described_class.devise_modules).to include(:database_authenticatable)
    end

    it "is registerable" do
      expect(described_class.devise_modules).to include(:registerable)
    end

    it "is recoverable" do
      expect(described_class.devise_modules).to include(:recoverable)
    end

    it "is rememberable" do
      expect(described_class.devise_modules).to include(:rememberable)
    end

    it "is validatable" do
      expect(described_class.devise_modules).to include(:validatable)
    end
  end

  describe "role management" do
    describe "#assign_owner_role_if_first_user" do
      it "assigns owner role to first user in account" do
        account = create(:account)
        user = create(:user, account: account)

        expect(user.has_role?(:owner, account)).to be true
      end

      it "does not assign owner role to subsequent users" do
        account = create(:account)
        first_user = create(:user, account: account)
        second_user = create(:user, account: account)

        expect(first_user.has_role?(:owner, account)).to be true
        expect(second_user.has_role?(:owner, account)).to be false
      end
    end

    describe "#has_role?" do
      it "returns true when user has the specified role" do
        user = create(:user, :admin)

        expect(user.has_role?(:admin, user.account)).to be true
      end

      it "returns false when user does not have the specified role" do
        account = create(:account)
        create(:user, account: account) # first user gets owner role
        user = create(:user, account: account)

        expect(user.has_role?(:admin, account)).to be false
      end
    end

    describe "role checking" do
      it "returns true when user has one of the specified scoped roles" do
        account = create(:account)
        create(:user, account: account) # first user gets owner role
        user = create(:user, :member, account: account)

        # Check scoped roles by checking each role individually
        has_role = [ :owner, :admin, :member ].any? { |role| user.has_role?(role, account) }
        expect(has_role).to be true
      end

      it "returns false when user has none of the specified scoped roles" do
        account = create(:account)
        create(:user, account: account) # first user gets owner role
        user = create(:user, account: account)

        # Check scoped roles by checking each role individually
        has_role = [ :admin, :member ].any? { |role| user.has_role?(role, account) }
        expect(has_role).to be false
      end
    end
  end
end
