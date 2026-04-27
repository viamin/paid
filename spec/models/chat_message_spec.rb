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
