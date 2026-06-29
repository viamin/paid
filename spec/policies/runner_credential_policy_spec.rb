# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerCredentialPolicy do
  describe "permissions" do
    describe "#index?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)

        expect(described_class.new(owner, credential)).to be_index
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        credential = create(:runner_credential, account: account, created_by: admin)

        expect(described_class.new(admin, credential)).to be_index
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(member, credential)).not_to be_index
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(viewer, credential)).not_to be_index
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, credential)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)

        expect(described_class.new(owner, credential)).to be_show
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        credential = create(:runner_credential, account: account, created_by: admin)

        expect(described_class.new(admin, credential)).to be_show
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(member, credential)).not_to be_show
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, credential)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)

        expect(described_class.new(owner, credential)).to be_create
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        credential = create(:runner_credential, account: account, created_by: admin)

        expect(described_class.new(admin, credential)).to be_create
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(member, credential)).not_to be_create
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(viewer, credential)).not_to be_create
      end
    end

    describe "#destroy?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)

        expect(described_class.new(owner, credential)).to be_destroy
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        credential = create(:runner_credential, account: account, created_by: admin)

        expect(described_class.new(admin, credential)).to be_destroy
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(member, credential)).not_to be_destroy
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, credential)).not_to be_destroy
      end
    end

    describe "#revoke?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)

        expect(described_class.new(owner, credential)).to be_revoke
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        credential = create(:runner_credential, account: account, created_by: admin)

        expect(described_class.new(admin, credential)).to be_revoke
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        credential = create(:runner_credential, account: account)

        expect(described_class.new(member, credential)).not_to be_revoke
      end

      it "does not permit users from different account" do
        account = create(:account)
        owner = create(:user, account: account)
        credential = create(:runner_credential, account: account, created_by: owner)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, credential)).not_to be_revoke
      end
    end
  end

  describe "Scope" do
    it "returns runner_credentials for the user's account" do
      account = create(:account)
      owner = create(:user, account: account)
      credential_in_account = create(:runner_credential, account: account, created_by: owner)
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      credential_in_other_account = create(:runner_credential, account: other_account, created_by: other_user)

      scope = described_class::Scope.new(owner, RunnerCredential).resolve

      expect(scope).to include(credential_in_account)
      expect(scope).not_to include(credential_in_other_account)
    end

    it "returns nothing for member" do
      account = create(:account)
      create(:user, account: account) # absorb owner role
      member = create(:user, :member, account: account)
      create(:runner_credential, account: account)

      scope = described_class::Scope.new(member, RunnerCredential).resolve

      expect(scope).to be_empty
    end

    it "raises error when user is not logged in" do
      expect {
        described_class::Scope.new(nil, RunnerCredential).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end
  end
end
