# frozen_string_literal: true

require "rails_helper"

RSpec.describe LinearToken do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
  end

  describe "validations" do
    subject { build(:linear_token) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:account_id) }
    it { is_expected.to validate_presence_of(:token) }

    describe "token format validation" do
      it "accepts valid Linear API key format" do
        token = build(:linear_token, token: "lin_api_#{SecureRandom.alphanumeric(32)}")
        expect(token).to be_valid
      end

      it "rejects tokens with invalid prefix" do
        token = build(:linear_token, token: "invalid_token_format")
        expect(token).not_to be_valid
        expect(token.errors[:token]).to include("must be a valid Linear API key format (lin_api_...)")
      end

      it "rejects tokens that are too short" do
        token = build(:linear_token, token: "lin_api_short")
        expect(token).not_to be_valid
        expect(token.errors[:token]).to include("must be a valid Linear API key format (lin_api_...)")
      end

      it "rejects empty tokens" do
        token = build(:linear_token, token: "")
        expect(token).not_to be_valid
        expect(token.errors[:token]).to include("can't be blank")
      end
    end

    describe "created_by account validation" do
      it "allows created_by from the same account" do
        account = create(:account)
        user = create(:user, account: account)
        token = build(:linear_token, account: account, created_by: user)

        expect(token).to be_valid
      end

      it "rejects created_by from a different account" do
        account = create(:account)
        other_account = create(:account)
        user = create(:user, account: other_account)
        token = build(:linear_token, account: account, created_by: user)

        expect(token).not_to be_valid
        expect(token.errors[:created_by]).to include("must belong to the same account")
      end

      it "allows nil created_by" do
        account = create(:account)
        token = build(:linear_token, account: account, created_by: nil)

        expect(token).to be_valid
      end
    end
  end

  describe "encryption" do
    it "encrypts the token field" do
      token = create(:linear_token, token: "lin_api_#{SecureRandom.alphanumeric(32)}")
      raw_token_in_db = described_class.connection.select_value(
        "SELECT token FROM linear_tokens WHERE id = #{token.id}"
      )

      expect(raw_token_in_db).not_to include("lin_api_")
    end

    it "decrypts the token when accessed" do
      original_token = "lin_api_#{SecureRandom.alphanumeric(32)}"
      linear_token = create(:linear_token, token: original_token)

      reloaded = described_class.find(linear_token.id)
      expect(reloaded.token).to eq(original_token)
    end
  end

  describe "scopes" do
    describe ".active" do
      it "includes tokens that are not revoked and not expired" do
        active_token = create(:linear_token)
        expect(described_class.active).to include(active_token)
      end

      it "excludes revoked tokens" do
        revoked_token = create(:linear_token, :revoked)
        expect(described_class.active).not_to include(revoked_token)
      end
    end

    describe ".revoked" do
      it "includes revoked tokens" do
        revoked_token = create(:linear_token, :revoked)
        expect(described_class.revoked).to include(revoked_token)
      end

      it "excludes non-revoked tokens" do
        active_token = create(:linear_token)
        expect(described_class.revoked).not_to include(active_token)
      end
    end
  end

  describe "instance methods" do
    describe "#active?" do
      it "returns true for non-revoked, non-expired token" do
        token = build(:linear_token)
        expect(token.active?).to be true
      end

      it "returns false for revoked token" do
        token = build(:linear_token, :revoked)
        expect(token.active?).to be false
      end
    end

    describe "#revoked?" do
      it "returns false when revoked_at is nil" do
        token = build(:linear_token)
        expect(token.revoked?).to be false
      end

      it "returns true when revoked_at is set" do
        token = build(:linear_token, :revoked)
        expect(token.revoked?).to be true
      end
    end

    describe "#revoke!" do
      it "sets revoked_at to current time" do
        token = create(:linear_token)

        freeze_time do
          token.revoke!
          expect(token.revoked_at).to eq(Time.current)
        end
      end

      it "makes the token inactive" do
        token = create(:linear_token)
        token.revoke!

        expect(token.active?).to be false
        expect(token.revoked?).to be true
      end
    end

    describe "#validation_pending?" do
      it "returns true when status is pending" do
        token = build(:linear_token, :pending_validation)
        expect(token.validation_pending?).to be true
      end

      it "returns false when status is validated" do
        token = build(:linear_token)
        expect(token.validation_pending?).to be false
      end
    end

    describe "#validated?" do
      it "returns true when status is validated" do
        token = build(:linear_token, validation_status: "validated")
        expect(token.validated?).to be true
      end

      it "returns false when status is pending" do
        token = build(:linear_token, :pending_validation)
        expect(token.validated?).to be false
      end
    end

    describe "#validation_failed?" do
      it "returns true when status is failed" do
        token = build(:linear_token, validation_status: "failed")
        expect(token.validation_failed?).to be true
      end

      it "returns false when status is validated" do
        token = build(:linear_token)
        expect(token.validation_failed?).to be false
      end
    end
  end
end
