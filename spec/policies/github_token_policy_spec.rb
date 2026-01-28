# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubTokenPolicy do
  subject { described_class }

  describe "permissions" do
    describe "#index?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)

        expect(described_class.new(owner, github_token)).to be_index
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        github_token = create(:github_token, account: account, created_by: admin)

        expect(described_class.new(admin, github_token)).to be_index
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        github_token = create(:github_token, account: account, created_by: member)

        expect(described_class.new(member, github_token)).to be_index
      end

      it "permits viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        github_token = create(:github_token, account: account)

        expect(described_class.new(viewer, github_token)).to be_index
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, github_token)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)

        expect(described_class.new(owner, github_token)).to be_show
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        github_token = create(:github_token, account: account, created_by: admin)

        expect(described_class.new(admin, github_token)).to be_show
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        github_token = create(:github_token, account: account, created_by: member)

        expect(described_class.new(member, github_token)).to be_show
      end

      it "permits viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        github_token = create(:github_token, account: account)

        expect(described_class.new(viewer, github_token)).to be_show
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, github_token)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)

        expect(described_class.new(owner, github_token)).to be_create
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        github_token = create(:github_token, account: account, created_by: admin)

        expect(described_class.new(admin, github_token)).to be_create
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        github_token = create(:github_token, account: account, created_by: member)

        expect(described_class.new(member, github_token)).to be_create
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        github_token = create(:github_token, account: account)

        expect(described_class.new(viewer, github_token)).not_to be_create
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, github_token)).not_to be_create
      end
    end

    describe "#update?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)

        expect(described_class.new(owner, github_token)).to be_update
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        github_token = create(:github_token, account: account, created_by: admin)

        expect(described_class.new(admin, github_token)).to be_update
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        github_token = create(:github_token, account: account, created_by: member)

        expect(described_class.new(member, github_token)).not_to be_update
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        github_token = create(:github_token, account: account)

        expect(described_class.new(viewer, github_token)).not_to be_update
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, github_token)).not_to be_update
      end
    end

    describe "#destroy?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)

        expect(described_class.new(owner, github_token)).to be_destroy
      end

      it "does not permit admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        github_token = create(:github_token, account: account, created_by: admin)

        expect(described_class.new(admin, github_token)).not_to be_destroy
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        github_token = create(:github_token, account: account, created_by: member)

        expect(described_class.new(member, github_token)).not_to be_destroy
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        github_token = create(:github_token, account: account)

        expect(described_class.new(viewer, github_token)).not_to be_destroy
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, github_token)).not_to be_destroy
      end
    end

    describe "#revoke?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)

        expect(described_class.new(owner, github_token)).to be_revoke
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        github_token = create(:github_token, account: account, created_by: admin)

        expect(described_class.new(admin, github_token)).to be_revoke
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        github_token = create(:github_token, account: account, created_by: member)

        expect(described_class.new(member, github_token)).not_to be_revoke
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        github_token = create(:github_token, account: account)

        expect(described_class.new(viewer, github_token)).not_to be_revoke
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        github_token = create(:github_token, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, github_token)).not_to be_revoke
      end
    end
  end

  describe "Scope" do
    it "returns github_tokens for the user's account" do
      account = create(:account)
      owner = create(:user, account: account)
      token_in_account = create(:github_token, account: account, created_by: owner)
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      token_in_other_account = create(:github_token, account: other_account, created_by: other_user)

      scope = described_class::Scope.new(owner, GithubToken).resolve

      expect(scope).to include(token_in_account)
      expect(scope).not_to include(token_in_other_account)
    end

    it "raises error when user is not logged in" do
      expect {
        described_class::Scope.new(nil, GithubToken).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end
  end
end
