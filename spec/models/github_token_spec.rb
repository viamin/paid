# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubToken do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
  end

  describe "validations" do
    subject { build(:github_token) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:account_id) }
    it { is_expected.to validate_presence_of(:token) }

    describe "token format validation" do
      it "accepts classic PAT format (ghp_)" do
        token = build(:github_token, token: "ghp_#{SecureRandom.alphanumeric(36)}")
        expect(token).to be_valid
      end

      it "accepts fine-grained PAT format (github_pat_)" do
        token = build(:github_token, token: "github_pat_#{SecureRandom.alphanumeric(22)}_#{SecureRandom.alphanumeric(40)}")
        expect(token).to be_valid
      end

      it "accepts OAuth token format (gho_)" do
        token = build(:github_token, token: "gho_#{SecureRandom.alphanumeric(36)}")
        expect(token).to be_valid
      end

      it "accepts user-to-server token format (ghu_)" do
        token = build(:github_token, token: "ghu_#{SecureRandom.alphanumeric(36)}")
        expect(token).to be_valid
      end

      it "accepts server-to-server token format (ghs_)" do
        token = build(:github_token, token: "ghs_#{SecureRandom.alphanumeric(36)}")
        expect(token).to be_valid
      end

      it "accepts refresh token format (ghr_)" do
        token = build(:github_token, token: "ghr_#{SecureRandom.alphanumeric(36)}")
        expect(token).to be_valid
      end

      it "rejects tokens with invalid prefix" do
        token = build(:github_token, token: "invalid_token_format")
        expect(token).not_to be_valid
        expect(token.errors[:token]).to include("must be a valid GitHub token format")
      end

      it "rejects tokens that are too short" do
        token = build(:github_token, token: "ghp_short")
        expect(token).not_to be_valid
        expect(token.errors[:token]).to include("must be a valid GitHub token format")
      end

      it "rejects empty tokens" do
        token = build(:github_token, token: "")
        expect(token).not_to be_valid
        expect(token.errors[:token]).to include("can't be blank")
      end
    end
  end

  describe "encryption" do
    it "encrypts the token field" do
      token = create(:github_token, token: "ghp_#{SecureRandom.alphanumeric(36)}")
      raw_token_in_db = described_class.connection.select_value(
        "SELECT token FROM github_tokens WHERE id = #{token.id}"
      )

      # Rails encryption stores an encrypted JSON payload, not the plain text
      expect(raw_token_in_db).not_to include("ghp_")
    end

    it "decrypts the token when accessed" do
      original_token = "ghp_#{SecureRandom.alphanumeric(36)}"
      github_token = create(:github_token, token: original_token)

      reloaded = described_class.find(github_token.id)
      expect(reloaded.token).to eq(original_token)
    end
  end

  describe "scopes" do
    describe ".active" do
      it "includes tokens that are not revoked and not expired" do
        active_token = create(:github_token)
        expect(described_class.active).to include(active_token)
      end

      it "includes tokens with nil expires_at" do
        token_without_expiry = create(:github_token, expires_at: nil)
        expect(described_class.active).to include(token_without_expiry)
      end

      it "includes tokens with future expires_at" do
        future_token = create(:github_token, expires_at: 1.week.from_now)
        expect(described_class.active).to include(future_token)
      end

      it "excludes revoked tokens" do
        revoked_token = create(:github_token, :revoked)
        expect(described_class.active).not_to include(revoked_token)
      end

      it "excludes expired tokens" do
        expired_token = create(:github_token, :expired)
        expect(described_class.active).not_to include(expired_token)
      end
    end

    describe ".expired" do
      it "includes tokens with past expires_at" do
        expired_token = create(:github_token, :expired)
        expect(described_class.expired).to include(expired_token)
      end

      it "excludes tokens without expires_at" do
        token_without_expiry = create(:github_token, expires_at: nil)
        expect(described_class.expired).not_to include(token_without_expiry)
      end

      it "excludes tokens with future expires_at" do
        future_token = create(:github_token, expires_at: 1.week.from_now)
        expect(described_class.expired).not_to include(future_token)
      end
    end

    describe ".revoked" do
      it "includes revoked tokens" do
        revoked_token = create(:github_token, :revoked)
        expect(described_class.revoked).to include(revoked_token)
      end

      it "excludes non-revoked tokens" do
        active_token = create(:github_token)
        expect(described_class.revoked).not_to include(active_token)
      end
    end
  end

  describe "instance methods" do
    describe "#active?" do
      it "returns true for non-revoked, non-expired token" do
        token = build(:github_token)
        expect(token.active?).to be true
      end

      it "returns true for token with nil expires_at" do
        token = build(:github_token, expires_at: nil)
        expect(token.active?).to be true
      end

      it "returns true for token with future expires_at" do
        token = build(:github_token, expires_at: 1.week.from_now)
        expect(token.active?).to be true
      end

      it "returns false for revoked token" do
        token = build(:github_token, :revoked)
        expect(token.active?).to be false
      end

      it "returns false for expired token" do
        token = build(:github_token, :expired)
        expect(token.active?).to be false
      end
    end

    describe "#expired?" do
      it "returns false when expires_at is nil" do
        token = build(:github_token, expires_at: nil)
        expect(token.expired?).to be false
      end

      it "returns false when expires_at is in the future" do
        token = build(:github_token, expires_at: 1.week.from_now)
        expect(token.expired?).to be false
      end

      it "returns true when expires_at is in the past" do
        token = build(:github_token, :expired)
        expect(token.expired?).to be true
      end
    end

    describe "#revoked?" do
      it "returns false when revoked_at is nil" do
        token = build(:github_token)
        expect(token.revoked?).to be false
      end

      it "returns true when revoked_at is set" do
        token = build(:github_token, :revoked)
        expect(token.revoked?).to be true
      end
    end

    describe "#revoke!" do
      it "sets revoked_at to current time" do
        token = create(:github_token)

        freeze_time do
          token.revoke!
          expect(token.revoked_at).to eq(Time.current)
        end
      end

      it "makes the token inactive" do
        token = create(:github_token)
        token.revoke!

        expect(token.active?).to be false
        expect(token.revoked?).to be true
      end
    end

    describe "#touch_last_used!" do
      it "updates last_used_at to current time" do
        token = create(:github_token)

        freeze_time do
          token.touch_last_used!
          expect(token.last_used_at).to eq(Time.current)
        end
      end
    end
  end

  describe "scopes attribute" do
    it "stores scopes as JSONB array" do
      token = create(:github_token, scopes: [ "repo", "read:org", "write:packages" ])
      reloaded = described_class.find(token.id)

      expect(reloaded.scopes).to eq([ "repo", "read:org", "write:packages" ])
    end

    it "defaults to empty array" do
      token = create(:github_token, scopes: [])
      expect(token.scopes).to eq([])
    end
  end

  describe "account association" do
    it "is destroyed when account is destroyed" do
      account = create(:account)
      user = create(:user, account: account)
      token = create(:github_token, account: account, created_by: user)

      expect { account.destroy }.to change(described_class, :count).by(-1)
      expect { token.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "user association" do
    it "allows token to exist without creator" do
      token = create(:github_token, :without_creator)
      expect(token.created_by).to be_nil
      expect(token).to be_valid
    end

    it "sets created_by to nil when user is destroyed" do
      account = create(:account)
      user = create(:user, account: account)
      token = create(:github_token, account: account, created_by: user)

      user.destroy
      token.reload

      expect(token.created_by).to be_nil
    end
  end
end
