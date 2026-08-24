# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerCredential do
  describe "validations" do
    it "requires a name" do
      credential = build(:runner_credential, name: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:name]).to include("can't be blank")
    end

    it "requires an auth kind" do
      credential = build(:runner_credential, auth_kind: nil)
      expect(credential).not_to be_valid
      expect(credential.errors[:auth_kind]).to include("can't be blank")
    end

    it "requires a token" do
      credential = build(:runner_credential, token: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:token]).to include("can't be blank")
    end

    it "requires a supported runner key" do
      credential = build(:runner_credential, runner_key: "not-supported")

      expect(credential).not_to be_valid
      expect(credential.errors[:runner_key]).to include("is not supported")
    end

    it "rejects duplicate names for the same account and runner key" do
      account = create(:account)
      create(:runner_credential, account: account, runner_key: "claude", name: "Claude Setup Token")
      duplicate = build(:runner_credential, account: account, runner_key: "claude", name: "Claude Setup Token")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "allows duplicate names across different runner keys" do
      account = create(:account)
      create(:runner_credential, account: account, runner_key: "claude", name: "Shared Name")
      new_credential = build(:runner_credential, account: account, runner_key: "codex", name: "Shared Name")

      expect(new_credential).to be_valid
    end

    it "validates created_by belongs to the same account" do
      account1 = create(:account)
      account2 = create(:account)
      other_user = create(:user, account: account2)
      credential = build(:runner_credential, account: account1, created_by: other_user)

      expect(credential).not_to be_valid
      expect(credential.errors[:created_by]).to include("must belong to the same account")
    end
  end

  describe ".active" do
    it "excludes revoked credentials and expired short-lived credentials" do
      active = create(:runner_credential)
      long_lived = create(:runner_credential, :long_lived)
      create(:runner_credential, :revoked)
      expired = create(:runner_credential, :expired)

      expect(described_class.active).to contain_exactly(active, long_lived)
      expect(described_class.active).not_to include(expired)
    end
  end

  describe ".revoked" do
    it "includes revoked credentials" do
      create(:runner_credential)
      revoked = create(:runner_credential, :revoked)

      expect(described_class.revoked).to contain_exactly(revoked)
    end
  end

  describe "#active?" do
    it "returns true for an unrevoked credential without an expiry" do
      credential = build(:runner_credential, revoked_at: nil)

      expect(credential).to be_active
    end

    it "returns false for an expired short-lived credential" do
      credential = build(:runner_credential, :expired)

      expect(credential).not_to be_active
    end

    it "returns false when revoked_at is set" do
      credential = build(:runner_credential, :revoked)

      expect(credential).not_to be_active
    end
  end

  describe "#expired?" do
    it "returns true for an expired short-lived credential" do
      credential = build(:runner_credential, :expired)

      expect(credential).to be_expired
    end

    it "returns false for long-lived credentials" do
      credential = build(:runner_credential, :long_lived, expires_at: 1.hour.ago)

      expect(credential).not_to be_expired
    end
  end

  describe "#revoked?" do
    it "returns false when revoked_at is nil" do
      credential = build(:runner_credential, revoked_at: nil)

      expect(credential).not_to be_revoked
    end

    it "returns true when revoked_at is set" do
      credential = build(:runner_credential, :revoked)

      expect(credential).to be_revoked
    end
  end

  describe "#revoke!" do
    it "sets revoked_at to the current time" do
      credential = create(:runner_credential)

      freeze_time do
        credential.revoke!

        expect(credential.revoked_at).to eq(Time.current)
        expect(credential).to be_revoked
        expect(credential).not_to be_active
      end
    end
  end

  describe "#display_name" do
    it "maps the stored runner key to the runner display name" do
      credential = build(:runner_credential, runner_key: "claude")

      expect(credential.display_name).to eq(Runner.display_name_for("claude"))
    end
  end

  # @spec SUBSCRIPTION-RUNNER-AUTH-004
  describe "#expiry_label" do
    it "describes a credential without an expiry as long-lived" do
      expect(build(:runner_credential, expires_at: nil).expiry_label).to eq("long-lived")
    end

    it "describes a long-lived credential as long-lived even with an expiry set" do
      credential = build(:runner_credential, :long_lived, expires_at: 1.hour.from_now)

      expect(credential.expiry_label).to eq("long-lived")
    end

    it "includes the formatted expiry for short-lived credentials" do
      expires_at = 1.week.from_now
      credential = build(:runner_credential, expires_at: expires_at)

      expect(credential.expiry_label).to eq("expires #{I18n.l(expires_at, format: :long)}")
    end
  end
end
