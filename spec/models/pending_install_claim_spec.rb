# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingInstallClaim, type: :model do
  let(:account) { create(:account) }
  let(:installation_id) { 12_345_678 }

  describe "validations" do
    it "is valid with the required attributes" do
      claim = build(:pending_install_claim, account: account, github_installation_id: installation_id)
      expect(claim).to be_valid
    end

    it "rejects an unknown source" do
      claim = build(:pending_install_claim, account: account, source: "rogue")
      expect(claim).not_to be_valid
      expect(claim.errors[:source]).to be_present
    end

    it "enforces uniqueness of (account_id, github_installation_id)" do
      create(:pending_install_claim, account: account, github_installation_id: installation_id)
      duplicate = build(:pending_install_claim, account: account, github_installation_id: installation_id)
      expect(duplicate).not_to be_valid
    end
  end

  describe ".upsert_for_callback!" do
    it "creates a new claim with the configured TTL" do
      freeze_time do
        claim = described_class.upsert_for_callback!(
          account: account,
          installation_id: installation_id,
          source: "callback_with_state",
          state_token: "tok"
        )

        expect(claim).to be_persisted
        expect(claim.expires_at).to eq(1.hour.from_now)
        expect(claim.source).to eq("callback_with_state")
        expect(claim.state_token).to eq("tok")
      end
    end

    it "refreshes the TTL on a repeat call for the same (account, installation) pair" do
      described_class.upsert_for_callback!(
        account: account,
        installation_id: installation_id,
        source: "callback_with_state"
      )

      travel_to(30.minutes.from_now) do
        described_class.upsert_for_callback!(
          account: account,
          installation_id: installation_id,
          source: "operator_setup"
        )
      end

      claim = TenantContext.with_system_access do
        described_class.find_by(github_installation_id: installation_id)
      end
      expect(claim.source).to eq("operator_setup")
      expect(claim.expires_at).to be > 30.minutes.from_now
    end

    it "is a no-op when installation_id is blank" do
      expect {
        described_class.upsert_for_callback!(
          account: account,
          installation_id: nil,
          source: "callback_with_state"
        )
      }.not_to change(described_class, :count)
    end
  end

  describe ".find_active" do
    it "returns the active claim for the installation id" do
      claim = create(:pending_install_claim, account: account, github_installation_id: installation_id)
      expect(described_class.find_active(installation_id)).to eq(claim)
    end

    it "skips expired claims" do
      create(:pending_install_claim, account: account, github_installation_id: installation_id,
        expires_at: 1.hour.ago)
      expect(described_class.find_active(installation_id)).to be_nil
    end

    it "returns nil for a missing installation id" do
      expect(described_class.find_active(nil)).to be_nil
    end
  end

  describe "scopes" do
    it ".active excludes expired claims" do
      active_claim = create(:pending_install_claim, account: account, github_installation_id: 1)
      expired_claim = create(:pending_install_claim, account: account, github_installation_id: 2,
        expires_at: 1.hour.ago)

      expect(described_class.active).to contain_exactly(active_claim)
      expect(described_class.expired).to contain_exactly(expired_claim)
    end
  end
end
