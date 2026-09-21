# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatMessage do
  subject(:chat_message) { build(:chat_message) }

  describe "associations" do
    it { is_expected.to belong_to(:chat_session) }
  end

  describe "validations" do
    it { is_expected.to validate_inclusion_of(:role).in_array(described_class::ROLES) }

    it "validates uniqueness of external_id" do
      create(:chat_message)
      expect(chat_message).to validate_uniqueness_of(:external_id).case_insensitive
    end

    it "validates presence of content for non-tool messages" do
      message = build(:chat_message, role: "user", content: nil)
      expect(message).not_to be_valid
      expect(message.errors[:content]).to be_present
    end

    it "allows nil content for tool messages" do
      message = build(:chat_message, :tool)
      expect(message).to be_valid
    end

    it "allows nil content for assistant messages with tool calls" do
      message = build(:chat_message, :tool_call)
      expect(message).to be_valid
    end
  end

  describe "#token_limit_error?" do
    # @spec CHAT-API-014
    it "is true for a system message flagged as a token-limit rejection" do
      message = build(:chat_message, :system, metadata: { "token_limit_error" => true })
      expect(message.token_limit_error?).to be true
    end

    it "is false for a regular system message" do
      message = build(:chat_message, :system)
      expect(message.token_limit_error?).to be false
    end
  end

  describe "#rate_limit_paused?" do
    # @spec CHAT-API-017
    it "is true for a system message flagged as a rate-limit pause" do
      message = build(:chat_message, :system, metadata: { "rate_limit_paused" => true })
      expect(message.rate_limit_paused?).to be true
    end

    it "is false for a regular system message" do
      message = build(:chat_message, :system)
      expect(message.rate_limit_paused?).to be false
    end
  end

  describe "#provider_error_notice?" do
    # @spec CHAT-API-017
    it "is true for a system message flagged as a provider-error notice" do
      message = build(:chat_message, :system, metadata: { "provider_error_notice" => true })
      expect(message.provider_error_notice?).to be true
    end

    it "is false for a regular system message" do
      message = build(:chat_message, :system)
      expect(message.provider_error_notice?).to be false
    end
  end

  describe "#display_content" do
    # @spec CHAT-API-016
    it "hides a leading reasoning block while keeping the answer and stored content" do
      message = build(:chat_message, :assistant, content: "<think>private reasoning</think>\n\nThe answer is **42**.")

      expect(message.display_content).to eq("The answer is **42**.")
      expect(message.content).to start_with("<think>")
    end

    it "keeps ordinary HTML-looking text visible" do
      message = build(:chat_message, :assistant, content: "Use <strong>care</strong> here")

      expect(message.display_content).to eq(message.content)
    end
  end

  describe "scopes" do
    let(:chat_session) { create(:chat_session) }

    describe ".chronological" do
      it "returns messages ordered by created_at ascending" do
        older = create(:chat_message, chat_session: chat_session, created_at: 2.minutes.ago)
        newer = create(:chat_message, chat_session: chat_session, created_at: 1.minute.ago)

        expect(described_class.chronological).to eq([ older, newer ])
      end
    end

    describe ".for_conversation" do
      it "returns user, assistant, and tool messages in chronological order" do
        create(:chat_message, :system, chat_session: chat_session)
        user_msg = create(:chat_message, chat_session: chat_session, created_at: 1.minute.ago)
        assistant_msg = create(:chat_message, :assistant, chat_session: chat_session, created_at: Time.current)

        expect(described_class.for_conversation).to eq([ user_msg, assistant_msg ])
      end
    end
  end
end
