# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServiceContainerPolicy do
  subject { described_class.new(user, service_container) }

  let(:account) { create(:account) }
  let(:service_container) { create(:service_container) }

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
    it { is_expected.not_to be_destroy }
  end

  context "when user is a member" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :member, account: account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a viewer" do
    before { create(:user, account: account) } # absorb owner role

    let(:user) { create(:user, :viewer, account: account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  describe described_class::Scope do
    subject(:scope) { described_class.new(user, ServiceContainer).resolve }

    let!(:service_container) { create(:service_container) }

    context "when user is an owner" do
      let(:user) { create(:user, :owner, account: account) }

      it "returns all service containers" do
        expect(scope).to include(service_container)
      end
    end

    context "when user is an admin" do
      before { create(:user, account: account) } # absorb owner role

      let(:user) { create(:user, :admin, account: account) }

      it "returns all service containers" do
        expect(scope).to include(service_container)
      end
    end

    context "when user is a member" do
      before { create(:user, account: account) } # absorb owner role

      let(:user) { create(:user, :member, account: account) }

      it "returns no service containers" do
        expect(scope).to be_empty
      end
    end

    context "when user is a viewer" do
      before { create(:user, account: account) } # absorb owner role

      let(:user) { create(:user, :viewer, account: account) }

      it "returns no service containers" do
        expect(scope).to be_empty
      end
    end
  end
end
