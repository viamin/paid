# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatMessagePolicy do
  describe "#create? and #resolve?" do
    it "allows sending or resolving a closed interactive inbox chat, but denies an archived one" do
      # @spec QUESTION-EXPLORATION-001
      account = create(:account)
      user = create(:user, :owner, account:)
      project = create(:project, account:, created_by: user)
      chat_session = create(
        :chat_session,
        :closed,
        account:,
        project:,
        created_by: user,
        inbox_item_key: "clarifying_questions:1"
      )
      message = create(:chat_message, chat_session:)

      expect(described_class.new(user, ChatMessage.new(chat_session:))).to be_create
      expect(described_class.new(user, message)).to be_resolve

      chat_session.update!(status: "archived")
      expect(described_class.new(user, ChatMessage.new(chat_session:))).not_to be_create
      expect(described_class.new(user, message)).not_to be_resolve
    end
  end
end
