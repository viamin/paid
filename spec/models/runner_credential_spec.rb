# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnerCredential do
  describe "validations" do
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

    it "rejects duplicate active credentials for the same account and runner key" do
      account = create(:account)
      create(:runner_credential, account: account, runner_key: "claude")
      duplicate = build(:runner_credential, account: account, runner_key: "claude")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:runner_key]).to include("already has a credential")
    end

    it "allows duplicate credentials if the first is revoked" do
      account = create(:account)
      create(:runner_credential, :revoked, account: account, runner_key: "claude")
      new_credential = build(:runner_credential, account: account, runner_key: "claude")

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
    it "excludes revoked credentials" do
      active = create(:runner_credential)
      create(:runner_credential, :revoked)

      expect(described_class.active).to contain_exactly(active)
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
    it "returns true when revoked_at is nil" do
      credential = build(:runner_credential, revoked_at: nil)

      expect(credential).to be_active
    end

    it "returns false when revoked_at is set" do
      credential = build(:runner_credential, :revoked)

      expect(credential).not_to be_active
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
end
