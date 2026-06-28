# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerCredentialPolicy do
  describe "permissions" do
    let(:account) { create(:account) }
    let(:owner) { create(:user, :owner, account: account) }
    let(:admin) { create(:user, :admin, account: account) }
    let(:member) { create(:user, :member, account: account) }
    let(:other_account) { create(:account) }
    let(:other_user) { create(:user, account: other_account) }
    let(:runner) { create(:runner, user: create(:user, account: account)) }
    let(:credential) { create(:runner_credential, runner: runner, account: account) }

    describe "#index?" do
      it "permits owner" do
        expect(described_class.new(owner, RunnerCredential)).to be_index
      end

      it "permits admin" do
        expect(described_class.new(admin, RunnerCredential)).to be_index
      end

      it "denies member" do
        expect(described_class.new(member, RunnerCredential)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits owner" do
        expect(described_class.new(owner, credential)).to be_show
      end

      it "permits admin" do
        expect(described_class.new(admin, credential)).to be_show
      end

      it "denies member" do
        expect(described_class.new(member, credential)).not_to be_show
      end

      it "denies user from different account" do
        expect(described_class.new(other_user, credential)).not_to be_show
      end
    end

    describe "#new?" do
      it "permits owner" do
        expect(described_class.new(owner, RunnerCredential.new(account: account))).to be_new
      end

      it "permits admin" do
        expect(described_class.new(admin, RunnerCredential.new(account: account))).to be_new
      end

      it "denies member" do
        expect(described_class.new(member, RunnerCredential.new(account: account))).not_to be_new
      end
    end

    describe "#create?" do
      it "permits owner" do
        expect(described_class.new(owner, RunnerCredential.new(account: account))).to be_create
      end

      it "permits admin" do
        expect(described_class.new(admin, RunnerCredential.new(account: account))).to be_create
      end

      it "denies member" do
        expect(described_class.new(member, RunnerCredential.new(account: account))).not_to be_create
      end
    end

    describe "#destroy?" do
      it "permits owner" do
        expect(described_class.new(owner, credential)).to be_destroy
      end

      it "permits admin" do
        expect(described_class.new(admin, credential)).to be_destroy
      end

      it "denies member" do
        expect(described_class.new(member, credential)).not_to be_destroy
      end

      it "denies user from different account" do
        expect(described_class.new(other_user, credential)).not_to be_destroy
      end
    end
  end

  describe "Scope" do
    let(:account_primary) { create(:account) }
    let(:account_secondary) { create(:account) }
    let(:owner_primary) { create(:user, :owner, account: account_primary) }
    let(:owner_secondary) { create(:user, :owner, account: account_secondary) }
    let(:runner_primary) { create(:runner, user: create(:user, account: account_primary)) }
    let(:runner_secondary) { create(:runner, user: create(:user, account: account_secondary)) }
    let!(:credential_primary) { create(:runner_credential, runner: runner_primary, account: account_primary) }
    let!(:credential_secondary) { create(:runner_credential, runner: runner_secondary, account: account_secondary) }

    it "shows only credentials from the user's account" do
      scope = described_class::Scope.new(owner_primary, RunnerCredential.all).resolve

      expect(scope).to contain_exactly(credential_primary)
    end

    it "shows credentials for the secondary user's account" do
      scope = described_class::Scope.new(owner_secondary, RunnerCredential.all).resolve

      expect(scope).to contain_exactly(credential_secondary)
    end
  end
end
