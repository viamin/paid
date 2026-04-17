# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrTemplatePolicy do
  subject { described_class.new(user, pr_template) }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:pr_template) { create(:pr_template, account: account, project: project) }

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

  context "when user is a member with a user-level template they own" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }
    let(:pr_template) { create(:pr_template, account: account, user: user) }

    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  context "when user is a member with a user-level template owned by another user" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }
    let(:other_user) { create(:user, :member, account: account) }
    let(:pr_template) { create(:pr_template, account: account, user: other_user) }

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
    subject(:scope) { described_class.new(user, PrTemplate).resolve }

    let!(:pr_template) { create(:pr_template, account: account) }
    let!(:other_template) { create(:pr_template, account: create(:account)) }

    context "when user is an owner" do
      let(:user) { create(:user, :owner, account: account) }

      it "returns templates scoped to the user's account" do
        expect(scope).to include(pr_template)
        expect(scope).not_to include(other_template)
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
