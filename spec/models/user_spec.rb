# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:account_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:member_accounts).through(:account_memberships).source(:account) }
    it { is_expected.to have_many(:project_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:member_projects).through(:project_memberships).source(:project) }
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

      it "works with project-scoped roles" do
        account = create(:account)
        user = create(:user, account: account)
        project = create(:project, account: account)

        user.add_role(:project_admin, project)

        expect(user.has_role?(:project_admin, project)).to be true
        expect(user.has_role?(:admin, project)).to be true
      end
    end

    describe "#has_any_role?" do
      it "returns true when user has one of the specified scoped roles" do
        account = create(:account)
        create(:user, account: account) # first user gets owner role
        user = create(:user, :member, account: account)

        expect(user.has_any_role?(:owner, :admin, :member, account)).to be true
      end

      it "returns false when user has none of the specified scoped roles" do
        account = create(:account)
        create(:user, account: account) # first user gets owner role
        user = create(:user, account: account)

        expect(user.has_any_role?(:admin, :member, account)).to be false
      end
    end

    describe "#add_role" do
      it "creates a membership with the specified role" do
        account = create(:account)
        user = create(:user, account: account)
        other_account = create(:account)

        user.add_role(:admin, other_account)

        expect(user.has_role?(:admin, other_account)).to be true
      end

      it "updates existing membership role" do
        account = create(:account)
        create(:user, account: account) # first user
        user = create(:user, :member, account: account)

        user.add_role(:admin, account)

        expect(user.has_role?(:admin, account)).to be true
        expect(user.has_role?(:member, account)).to be false
      end

      it "works with projects" do
        account = create(:account)
        user = create(:user, account: account)
        project = create(:project, account: account)

        user.add_role(:project_member, project)

        expect(user.has_role?(:project_member, project)).to be true
      end
    end

    describe "#remove_role" do
      it "removes the membership" do
        account = create(:account)
        user = create(:user, :admin, account: account)

        result = user.remove_role(:admin, account)

        expect(result).to be true
        expect(user.has_role?(:admin, account)).to be false
      end

      it "returns false if role does not match" do
        account = create(:account)
        user = create(:user, :admin, account: account)

        result = user.remove_role(:member, account)

        expect(result).to be false
        expect(user.has_role?(:admin, account)).to be true
      end
    end

    describe "#role_on" do
      it "returns the role for an account" do
        user = create(:user, :admin)

        expect(user.role_on(user.account)).to eq("admin")
      end

      it "returns nil if no membership exists" do
        account = create(:account)
        user = create(:user, account: account)
        other_account = create(:account)

        expect(user.role_on(other_account)).to be_nil
      end
    end

    describe "#membership_for" do
      it "returns the account membership" do
        user = create(:user, :admin)

        membership = user.membership_for(user.account)

        expect(membership).to be_an(AccountMembership)
        expect(membership.admin?).to be true
      end

      it "returns the project membership" do
        account = create(:account)
        user = create(:user, account: account)
        project = create(:project, account: account)
        user.add_role(:member, project)

        membership = user.membership_for(project)

        expect(membership).to be_a(ProjectMembership)
        expect(membership.member?).to be true
      end
    end
  end
end
