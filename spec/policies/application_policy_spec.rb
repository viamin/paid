# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationPolicy do
  subject { described_class }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  describe "permissions" do
    context "when user is in the same account" do
      # First user gets owner role automatically, subsequent users don't
      let!(:account_owner) { create(:user, account: account) }
      let(:owner) { account_owner }
      let(:admin) { create(:user, :admin, account: account) }
      let(:member) { create(:user, :member, account: account) }
      let(:viewer) { create(:user, :viewer, account: account) }

      describe "#index?" do
        it "permits owner" do
          expect(described_class.new(owner, account)).to be_index
        end

        it "permits admin" do
          expect(described_class.new(admin, account)).to be_index
        end

        it "permits member" do
          expect(described_class.new(member, account)).to be_index
        end

        it "permits viewer" do
          expect(described_class.new(viewer, account)).to be_index
        end
      end

      describe "#show?" do
        it "permits owner" do
          expect(described_class.new(owner, account)).to be_show
        end

        it "permits admin" do
          expect(described_class.new(admin, account)).to be_show
        end

        it "permits member" do
          expect(described_class.new(member, account)).to be_show
        end

        it "permits viewer" do
          expect(described_class.new(viewer, account)).to be_show
        end
      end

      describe "#create?" do
        it "permits owner" do
          expect(described_class.new(owner, account)).to be_create
        end

        it "permits admin" do
          expect(described_class.new(admin, account)).to be_create
        end

        it "permits member" do
          expect(described_class.new(member, account)).to be_create
        end

        it "does not permit viewer" do
          expect(described_class.new(viewer, account)).not_to be_create
        end
      end

      describe "#update?" do
        it "permits owner" do
          expect(described_class.new(owner, account)).to be_update
        end

        it "permits admin" do
          expect(described_class.new(admin, account)).to be_update
        end

        it "does not permit member" do
          expect(described_class.new(member, account)).not_to be_update
        end

        it "does not permit viewer" do
          expect(described_class.new(viewer, account)).not_to be_update
        end
      end

      describe "#destroy?" do
        it "permits owner" do
          expect(described_class.new(owner, account)).to be_destroy
        end

        it "permits admin" do
          expect(described_class.new(admin, account)).to be_destroy
        end

        it "does not permit member" do
          expect(described_class.new(member, account)).not_to be_destroy
        end

        it "does not permit viewer" do
          expect(described_class.new(viewer, account)).not_to be_destroy
        end
      end
    end

    context "when user is from different account" do
      let(:other_user) { create(:user, :owner, account: other_account) }

      describe "#index?" do
        it "does not permit user from different account" do
          expect(described_class.new(other_user, account)).not_to be_index
        end
      end

      describe "#show?" do
        it "does not permit user from different account" do
          expect(described_class.new(other_user, account)).not_to be_show
        end
      end

      describe "#create?" do
        it "does not permit user from different account" do
          expect(described_class.new(other_user, account)).not_to be_create
        end
      end

      describe "#update?" do
        it "does not permit user from different account" do
          expect(described_class.new(other_user, account)).not_to be_update
        end
      end

      describe "#destroy?" do
        it "does not permit user from different account" do
          expect(described_class.new(other_user, account)).not_to be_destroy
        end
      end
    end
  end

  describe ApplicationPolicy::Scope do
    let(:user) { create(:user, account: account) }

    it "scopes records to the user's account" do
      scope = described_class.new(user, Account)

      expect(scope.resolve.to_sql).to include("account")
    end
  end
end
