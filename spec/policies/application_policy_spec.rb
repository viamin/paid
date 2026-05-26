# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationPolicy do
  subject { described_class }

  describe "permissions" do
    describe "#index?" do
      it "permits users in same account" do
        account = create(:account)
        user = create(:user, account: account)

        expect(described_class.new(user, account)).to be_index
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, account)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits users in same account" do
        account = create(:account)
        user = create(:user, account: account)

        expect(described_class.new(user, account)).to be_show
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, account)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)

        expect(described_class.new(owner, account)).to be_create
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)

        expect(described_class.new(admin, account)).to be_create
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)

        expect(described_class.new(member, account)).to be_create
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)

        expect(described_class.new(viewer, account)).not_to be_create
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, account)).not_to be_create
      end
    end

    describe "#new?" do
      it "matches create? permissions" do
        account = create(:account)
        create(:user, account: account)
        member = create(:user, :member, account: account)

        expect(described_class.new(member, account)).to be_new
      end

      it "does not permit users who cannot create" do
        account = create(:account)
        create(:user, account: account)
        viewer = create(:user, :viewer, account: account)

        expect(described_class.new(viewer, account)).not_to be_new
      end
    end

    describe "#update?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)

        expect(described_class.new(owner, account)).to be_update
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)

        expect(described_class.new(admin, account)).to be_update
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)

        expect(described_class.new(member, account)).not_to be_update
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)

        expect(described_class.new(viewer, account)).not_to be_update
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, account)).not_to be_update
      end
    end

    describe "#destroy?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)

        expect(described_class.new(owner, account)).to be_destroy
      end

      it "does not permit admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)

        expect(described_class.new(admin, account)).not_to be_destroy
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)

        expect(described_class.new(member, account)).not_to be_destroy
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)

        expect(described_class.new(viewer, account)).not_to be_destroy
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, account)).not_to be_destroy
      end
    end

    describe "#edit?" do
      it "matches update? permissions" do
        account = create(:account)
        create(:user, account: account)
        admin = create(:user, :admin, account: account)

        expect(described_class.new(admin, account)).to be_edit
      end

      it "does not permit users who cannot update" do
        account = create(:account)
        create(:user, account: account)
        viewer = create(:user, :viewer, account: account)

        expect(described_class.new(viewer, account)).not_to be_edit
      end
    end
  end

  describe "records with an account association" do
    it "authorizes against the record account" do
      account = create(:account)
      user = create(:user, account: account)
      record = create(:project, account: account)

      expect(described_class.new(user, record)).to be_show
    end
  end

  describe ApplicationPolicy::Scope do
    it "raises when no user is present" do
      expect {
        ApplicationPolicy::Scope.new(nil, User).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end

    it "scopes records to the user's account" do
      account = create(:account)
      user = create(:user, account: account)
      in_account = user
      out_of_account = create(:user, account: create(:account))
      scope = ApplicationPolicy::Scope.new(user, User)

      expect(scope.resolve).to contain_exactly(in_account)
      expect(scope.resolve).not_to include(out_of_account)
    end

    it "raises NotImplementedError for models without account association" do
      account = create(:account)
      user = create(:user, account: account)
      scope = ApplicationPolicy::Scope.new(user, Account)

      expect { scope.resolve }.to raise_error(NotImplementedError)
    end
  end
end
