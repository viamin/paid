# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerCredential do
  describe "validations" do
    it "is valid with minimal required attributes" do
      credential = build(:runner_credential)

      expect(credential).to be_valid
    end

    it "requires runner_key" do
      credential = build(:runner_credential, runner_key: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:runner_key]).to include("can't be blank")
    end

    it "requires a supported runner_key" do
      credential = build(:runner_credential, runner_key: "cluade")

      expect(credential).not_to be_valid
      expect(credential.errors[:runner_key]).to include("is not supported")
    end

    it "accepts supported runner_keys" do
      described_class.supported_runner_keys.each do |runner_key|
        credential = build(:runner_credential, runner_key:)

        expect(credential).to be_valid, "expected runner_key #{runner_key} to be valid"
      end
    end

    it "requires name" do
      credential = build(:runner_credential, name: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:name]).to include("can't be blank")
    end

    it "requires token" do
      credential = build(:runner_credential, token: nil)

      expect(credential).not_to be_valid
      expect(credential.errors[:token]).to include("can't be blank")
    end

    it "requires a valid auth_kind" do
      credential = build(:runner_credential, auth_kind: "unsupported")

      expect(credential).not_to be_valid
      expect(credential.errors[:auth_kind]).to include("is not included in the list")
    end

    it "accepts all valid auth_kinds" do
      RunnerCredential::AUTH_KINDS.each do |kind|
        credential = build(:runner_credential, auth_kind: kind)

        expect(credential).to be_valid, "expected auth_kind #{kind} to be valid"
      end
    end

    it "enforces uniqueness on (account_id, runner_key, name)" do
      existing = create(:runner_credential, runner_key: "claude", name: "My Token")
      duplicate = build(:runner_credential, account: existing.account, runner_key: "claude", name: "My Token")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to include("has already been taken")
    end

    it "allows same name with different runner_key" do
      existing = create(:runner_credential, runner_key: "claude", name: "My Token")
      other = build(:runner_credential, account: existing.account, runner_key: "codex", name: "My Token")

      expect(other).to be_valid
    end

    it "allows same runner_key and name across different accounts" do
      create(:runner_credential, runner_key: "claude", name: "My Token")
      other_account_credential = build(:runner_credential, runner_key: "claude", name: "My Token")

      expect(other_account_credential).to be_valid
    end

    it "rejects created_by from a different account" do
      credential = create(:runner_credential)
      credential.created_by = create(:user)

      expect(credential).not_to be_valid
      expect(credential.errors[:created_by]).to include("must belong to the same account")
    end
  end

  describe ".active" do
    it "excludes revoked credentials" do
      active = create(:runner_credential)
      create(:runner_credential, :revoked)

      expect(described_class.active).to contain_exactly(active)
    end

    it "excludes expired credentials" do
      active = create(:runner_credential)
      create(:runner_credential, :expired)

      expect(described_class.active).to contain_exactly(active)
    end

    it "includes credentials with future expiration" do
      credential = create(:runner_credential, expires_at: 1.day.from_now)

      expect(described_class.active).to include(credential)
    end

    it "includes credentials with no expiration" do
      credential = create(:runner_credential, expires_at: nil)

      expect(described_class.active).to include(credential)
    end

    it "includes long_lived credentials even with past expires_at" do
      credential = create(:runner_credential, :long_lived, expires_at: 1.hour.ago)

      expect(described_class.active).to include(credential)
    end
  end

  describe ".for_runner" do
    it "filters by runner_key" do
      claude = create(:runner_credential, runner_key: "claude")
      create(:runner_credential, runner_key: "codex")

      expect(described_class.for_runner("claude")).to contain_exactly(claude)
    end
  end

  describe "#active?" do
    it "returns true when not revoked and no expiry" do
      credential = build(:runner_credential, revoked_at: nil, expires_at: nil)

      expect(credential).to be_active
    end

    it "returns false when revoked" do
      credential = build(:runner_credential, :revoked)

      expect(credential).not_to be_active
    end

    it "returns false when expired" do
      credential = build(:runner_credential, :expired)

      expect(credential).not_to be_active
    end

    it "returns true for long_lived credential even with past expires_at" do
      credential = build(:runner_credential, :long_lived, expires_at: 1.hour.ago)

      expect(credential).to be_active
    end
  end

  describe "#expired?" do
    it "returns false when expires_at is nil" do
      credential = build(:runner_credential, expires_at: nil)

      expect(credential).not_to be_expired
    end

    it "returns true when expires_at is in the past" do
      credential = build(:runner_credential, expires_at: 1.minute.ago)

      expect(credential).to be_expired
    end

    it "returns true at the boundary when expires_at equals current time" do
      credential = build(:runner_credential, expires_at: Time.current)

      expect(credential).to be_expired
    end

    it "returns false when revoked even if expired" do
      credential = build(:runner_credential, :revoked, expires_at: 1.hour.ago)

      expect(credential).not_to be_expired
    end

    it "returns false for long_lived credential even if expires_at is in the past" do
      credential = build(:runner_credential, :long_lived, expires_at: 1.hour.ago)

      expect(credential).not_to be_expired
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

  describe "encryption" do
    it "stores token encrypted at rest" do
      credential = create(:runner_credential, token: "sk-ant-oat01-secret")

      raw_value = ActiveRecord::Base.connection.select_value(
        "SELECT token FROM runner_credentials WHERE id = #{credential.id}"
      )

      expect(raw_value).not_to eq("sk-ant-oat01-secret")
      expect(credential.token).to eq("sk-ant-oat01-secret")
    end

    it "excludes token from logidze history" do
      credential = create(:runner_credential, token: "sk-ant-oat01-secret")

      credential.update!(name: "Updated Credential", token: "sk-ant-oat01-rotated")

      log_history = credential.reload.log_data
      history = log_history.data.fetch("h")
      latest_change = history.last.fetch("c")
      log_data = log_history.to_json

      expect(latest_change).to eq(
        "name" => "Updated Credential",
        "updated_at" => latest_change.fetch("updated_at")
      )
      expect(log_data).not_to include("sk-ant-oat01-secret")
      expect(log_data).not_to include("sk-ant-oat01-rotated")
    end
  end

  describe "creator deletion" do
    it "nullifies created_by when the creator is destroyed" do
      account = create(:account)
      owner = create(:user, account: account)
      create(:user, :admin, account: account)
      credential = create(:runner_credential, account: account, created_by: owner)

      expect { owner.destroy! }
        .to change { credential.reload.created_by_id }
        .from(owner.id).to(nil)
    end
  end
end
