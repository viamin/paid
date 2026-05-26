# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubInstallation do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:projects).dependent(:restrict_with_error) }
  end

  describe "validations" do
    subject { build(:github_installation) }

    it { is_expected.to validate_presence_of(:github_installation_id) }
    it { is_expected.to validate_uniqueness_of(:github_installation_id).scoped_to(:account_id) }
  end

  describe "scopes" do
    let(:account) { create(:account) }
    let!(:active_install) { create(:github_installation, account: account) }
    let!(:suspended_install) { create(:github_installation, account: account, suspended_at: Time.current) }
    let!(:revoked_install) { create(:github_installation, account: account, revoked_at: Time.current) }

    it ".active returns installations that are not suspended or revoked" do
      expect(described_class.active).to include(active_install)
      expect(described_class.active).not_to include(suspended_install)
      expect(described_class.active).not_to include(revoked_install)
    end

    it ".suspended returns suspended installations" do
      expect(described_class.suspended).to include(suspended_install)
      expect(described_class.suspended).not_to include(active_install)
    end

    it ".revoked returns revoked installations" do
      expect(described_class.revoked).to include(revoked_install)
      expect(described_class.revoked).not_to include(active_install)
    end
  end

  describe "#active?" do
    it "returns true when not suspended or revoked" do
      install = build(:github_installation)
      expect(install.active?).to be(true)
    end

    it "returns false when suspended" do
      install = build(:github_installation, suspended_at: Time.current)
      expect(install.active?).to be(false)
    end

    it "returns false when revoked" do
      install = build(:github_installation, revoked_at: Time.current)
      expect(install.active?).to be(false)
    end
  end
end
