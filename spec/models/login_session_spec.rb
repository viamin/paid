# frozen_string_literal: true

require "rails_helper"

RSpec.describe LoginSession do
  # @spec SUBSCRIPTION-RUNNER-AUTH-005
  describe "provider-specific statuses" do
    it "rejects Claude sessions with Codex-only statuses" do
      session = build(:claude_login_session, status: "awaiting_authorization")

      expect(session).not_to be_valid
      expect(session.errors[:status]).to include("is not valid for claude")
    end

    it "rejects Codex sessions with Claude-only statuses" do
      session = build(:codex_login_session, status: "awaiting_code")

      expect(session).not_to be_valid
      expect(session.errors[:status]).to include("is not valid for codex")
    end

    it "allows the provider-specific in-progress status for each flow" do
      expect(build(:claude_login_session, status: "awaiting_code")).to be_valid
      expect(build(:codex_login_session, status: "awaiting_authorization")).to be_valid
    end
  end

  # @spec SUBSCRIPTION-RUNNER-AUTH-005
  describe "create defaults" do
    it "assigns the Codex poll interval before subclass callbacks populate provider" do
      account = create(:account)
      created_by = create(:user, account: account)

      session = CodexLoginSession.create!(
        account: account,
        created_by: created_by,
        credential_name: "Codex Subscription Login",
        provider: nil,
        poll_interval: nil
      )

      expect(session.provider).to eq("codex")
      expect(session.poll_interval).to eq(5)
    end
  end
end
