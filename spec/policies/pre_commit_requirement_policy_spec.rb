# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreCommitRequirementPolicy do
  subject { described_class.new(user, pre_commit_requirement) }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:pre_commit_requirement) { create(:pre_commit_requirement, account: account, project: project) }

  context "when user is an owner" do
    let(:user) { create(:user, :owner, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  context "when user is an admin" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :admin, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  context "when user is a member" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a viewer" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :viewer, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a member with a user-level requirement they own" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }
    let(:pre_commit_requirement) { create(:pre_commit_requirement, account: account, user: user) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  context "when user is a member with a user-level requirement owned by another user" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }
    let(:other_user) { create(:user, :member, account: account) }
    let(:pre_commit_requirement) { create(:pre_commit_requirement, account: account, user: other_user) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user belongs to a different account" do
    let(:other_account) { create(:account) }
    let(:user) { create(:user, :owner, account: other_account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  describe described_class::Scope do
    subject(:scope) { described_class.new(user, PreCommitRequirement).resolve }

    let!(:pre_commit_requirement) { create(:pre_commit_requirement, account: account) }
    let!(:other_requirement) { create(:pre_commit_requirement, account: create(:account)) }

    context "when user is an owner" do
      let(:user) { create(:user, :owner, account: account) }

      it "returns requirements scoped to the user's account" do
        expect(scope).to include(pre_commit_requirement)
        expect(scope).not_to include(other_requirement)
      end
    end

    context "when user is nil" do
      let(:user) { nil }

      it "raises NotAuthorizedError" do
        expect { scope }.to raise_error(Pundit::NotAuthorizedError)
      end
    end
  end
end
