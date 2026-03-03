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
    let(:user) { create(:user, :admin, account: account) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a member" do
    let(:user) { create(:user, :member, account: account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end

  context "when user is a viewer" do
    let(:user) { create(:user, :viewer, account: account) }

    it { is_expected.not_to be_index }
    it { is_expected.not_to be_show }
    it { is_expected.not_to be_create }
    it { is_expected.not_to be_update }
    it { is_expected.not_to be_destroy }
  end
end
