# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAccessToken do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "token generation" do
    # @spec MOBILE-API-001
    it "builds a paid_pat_-prefixed urlsafe secret" do
      token = described_class.generate_plaintext

      expect(token).to start_with("paid_pat_")
      expect(token.split("paid_pat_").last).to match(/\A[A-Za-z0-9_-]{43}\z/)
    end

    it "generates unique secrets" do
      expect(described_class.generate_plaintext).not_to eq(described_class.generate_plaintext)
    end
  end

  describe ".digest" do
    # @spec MOBILE-API-001
    it "returns the SHA-256 base64 digest of the plaintext" do
      expect(described_class.digest("paid_pat_secret"))
        .to eq(Digest::SHA256.base64digest("paid_pat_secret"))
    end
  end

  describe ".build_for" do
    # @spec MOBILE-API-001
    it "assigns the user, their account, and a digest of the fresh secret" do
      token = described_class.build_for(user: user, name: "iPhone")

      expect(token.user).to eq(user)
      expect(token.account).to eq(account)
      expect(token.token_digest).to eq(described_class.digest(token.plaintext_token))
      expect(token).to be_valid
    end

    it "carries the full default scope set" do
      expect(described_class.build_for(user: user, name: "iPhone").scopes)
        .to contain_exactly("inbox", "chat")
    end

    it "accepts an optional expiry" do
      expires_at = 30.days.from_now
      token = described_class.build_for(user: user, name: "iPhone", expires_at: expires_at)

      expect(token.expires_at).to be_within(1.second).of(expires_at)
    end
  end

  describe "plaintext handling" do
    # @spec MOBILE-API-001
    it "persists only the digest — the plaintext is not a column" do
      token = described_class.create_for!(user: user, name: "iPhone")

      expect(token.reload.token_digest).to be_present
      expect(described_class.column_names).not_to include("plaintext_token", "token")
    end

    it "exposes the plaintext exactly once after creation, not to a fresh load" do
      token = described_class.create_for!(user: user, name: "iPhone")

      expect(token.plaintext_token).to start_with("paid_pat_")
      expect(described_class.find(token.id).plaintext_token).to be_nil
    end

    it "keeps the plaintext out of #inspect" do
      token = described_class.build_for(user: user, name: "iPhone")

      expect(token.inspect).not_to include(token.plaintext_token)
    end
  end

  describe "validations" do
    # @spec MOBILE-API-001
    it "requires a name" do
      token = described_class.build_for(user: user, name: "")

      expect(token).not_to be_valid
      expect(token.errors[:name]).to be_present
    end

    it "enforces name uniqueness per user" do
      described_class.create_for!(user: user, name: "iPhone")
      duplicate = described_class.build_for(user: user, name: "iPhone")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "allows the same name for a different user" do
      described_class.create_for!(user: user, name: "iPhone")
      other_user = create(:user, account: account)

      expect(described_class.build_for(user: other_user, name: "iPhone")).to be_valid
    end
  end

  describe "lifecycle states" do
    # @spec MOBILE-API-001
    it "is active by default" do
      expect(described_class.create_for!(user: user, name: "iPhone")).to be_active
    end

    it "marks revoked tokens" do
      token = described_class.create_for!(user: user, name: "iPhone")
      token.revoke!

      expect(token.reload).to be_revoked
      expect(token.reload).not_to be_active
    end

    it "marks expired tokens" do
      token = described_class.create_for!(user: user, name: "iPhone", expires_at: 1.minute.ago)

      expect(token).to be_expired
      expect(token).not_to be_active
    end

    it "treats a future expiry as active" do
      token = described_class.create_for!(user: user, name: "iPhone", expires_at: 1.day.from_now)

      expect(token).to be_active
    end
  end

  describe ".resolve" do
    # @spec MOBILE-API-002
    it "resolves a valid bearer value to its token" do
      token = described_class.create_for!(user: user, name: "iPhone")

      expect(described_class.resolve(token.plaintext_token)).to eq(token)
    end

    it "returns nil for values without the paid_pat_ prefix" do
      expect(described_class.resolve("ghp_not_a_paid_token")).to be_nil
      expect(described_class.resolve("")).to be_nil
      expect(described_class.resolve(nil)).to be_nil
    end

    it "returns nil for unknown secrets" do
      expect(described_class.resolve("paid_pat_#{SecureRandom.urlsafe_base64(32)}")).to be_nil
    end

    it "returns nil for revoked tokens" do
      token = described_class.create_for!(user: user, name: "iPhone")
      token.revoke!

      expect(described_class.resolve(token.plaintext_token)).to be_nil
    end

    it "returns nil for expired tokens" do
      token = described_class.create_for!(user: user, name: "iPhone", expires_at: 1.minute.ago)

      expect(described_class.resolve(token.plaintext_token)).to be_nil
    end

    it "preloads the bearer's user and account for tenant-context establishment" do
      token = described_class.create_for!(user: user, name: "iPhone")
      resolved = described_class.resolve(token.plaintext_token)

      expect(resolved.association(:user)).to be_loaded
      expect(resolved.association(:account)).to be_loaded
    end
  end

  describe "#touch_last_used!" do
    # @spec MOBILE-API-003
    it "stamps last_used_at when never used" do
      token = described_class.create_for!(user: user, name: "iPhone")

      expect { token.touch_last_used! }.to change { token.reload.last_used_at }.from(nil).to(be_within(1.second).of(Time.current))
    end

    it "skips the write when the stamp is fresh" do
      token = described_class.create_for!(user: user, name: "iPhone")
      token.touch_last_used!
      fresh = token.reload.last_used_at

      expect { token.touch_last_used! }.not_to change { token.reload.last_used_at }
      expect(token.last_used_at).to eq(fresh)
    end

    it "stamps again once the throttle window elapsed" do
      token = described_class.create_for!(user: user, name: "iPhone")
      token.update_columns(last_used_at: 6.minutes.ago)

      expect { token.touch_last_used! }.to change { token.reload.last_used_at }
    end

    it "does not gate authorization semantics — resolution stays independent of the stamp" do
      token = described_class.create_for!(user: user, name: "iPhone")
      token.touch_last_used!

      expect(described_class.resolve(token.plaintext_token)).to eq(token)
    end
  end

  describe "tenant isolation" do
    # @spec MOBILE-API-005
    it "scopes reads to the requesting user's tokens through the policy scope" do
      mine = described_class.create_for!(user: user, name: "iPhone")
      colleague = create(:user, account: account)
      described_class.create_for!(user: colleague, name: "Android")

      visible = PersonalAccessTokenPolicy::Scope.new(user, described_class).resolve

      expect(visible).to contain_exactly(mine)
    end

    it "allows the system-access bearer lookup to cross tenants" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      token = described_class.create_for!(user: other_user, name: "Android")

      expect(described_class.resolve(token.plaintext_token)).to eq(token)
    end
  end
end
