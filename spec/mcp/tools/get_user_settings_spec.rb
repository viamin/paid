# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetUserSettings do
  describe Tools::GetUserSettings do
    it "returns the current user's settings" do
      account = create(:account)
      user = create(:user, :member, account:)
      session = create(:chat_session, account:, created_by: user)

      result = described_class.new(user:, session:).call

      expect(result["theme_preference"]).to eq(user.settings.theme_preference)
    end
  end

  describe Tools::UpdateUserSettings do
    it "updates the current user's settings" do
      account = create(:account)
      user = create(:user, :member, account:)
      session = create(:chat_session, account:, created_by: user)

      result = described_class.new(user:, session:).call(
        settings: { theme_preference: "dark" },
        confirmed: true
      )

      expect(result["theme_preference"]).to eq("dark")
      expect(user.settings.reload.theme_preference).to eq("dark")
    end

    it "updates knowledge fallback runners" do
      account = create(:account)
      user = create(:user, :member, account:)
      session = create(:chat_session, account:, created_by: user)

      result = described_class.new(user:, session:).call(
        settings: {
          kb_embedding_fallback_runners: [ "openai", "deepseek" ],
          kb_chat_fallback_runners: [ "claude", "cursor" ]
        },
        confirmed: true
      )

      expect(result["kb_embedding_fallback_runners"]).to eq(%w[openai deepseek])
      expect(result["kb_chat_fallback_runners"]).to eq(%w[claude cursor])
      expect(user.settings.reload.kb_embedding_fallback_runners).to eq(%w[openai deepseek])
      expect(user.settings.kb_chat_fallback_runners).to eq(%w[claude cursor])
    end
  end

  describe Tools::GetTenantSettings do
    it "returns tenant settings for an owner" do
      account = create(:account)
      user = create(:user, :owner, account:)
      session = create(:chat_session, account:, created_by: user)

      result = described_class.new(user:, session:).call

      expect(result["max_concurrent_runs"]).to eq(account.tenant_setting!.max_concurrent_runs)
    end
  end

  describe Tools::UpdateTenantSettings do
    it "updates tenant settings for an owner" do
      account = create(:account)
      user = create(:user, :owner, account:)
      session = create(:chat_session, account:, created_by: user)

      result = described_class.new(user:, session:).call(
        settings: { max_concurrent_runs: 7 },
        confirmed: true
      )

      expect(result["max_concurrent_runs"]).to eq(7)
      expect(account.tenant_setting!.reload.max_concurrent_runs).to eq(7)
    end
  end
end
