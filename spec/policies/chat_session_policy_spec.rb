# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessionPolicy do
  describe "Scope" do
    it "keeps another account member's interactive inbox chat and messages out of the scope" do
      # @spec QUESTION-EXPLORATION-014
      account = create(:account)
      creator = create(:user, account:)
      member = create(:user, :member, account:)
      project = create(:project, account:, created_by: creator)
      inbox_chat = create(:chat_session, account:, project:, created_by: creator, inbox_item_key: "clarifying_questions:1")
      regular_chat = create(:chat_session, account:, project:, created_by: creator)
      inbox_message = create(:chat_message, chat_session: inbox_chat)
      regular_message = create(:chat_message, chat_session: regular_chat)

      sessions = described_class::Scope.new(member, ChatSession).resolve
      messages = ChatMessagePolicy::Scope.new(member, ChatMessage).resolve

      expect(sessions).to contain_exactly(regular_chat)
      expect(messages).to contain_exactly(regular_message)
      expect(messages).not_to include(inbox_message)
    end

    it "includes a creator's inbox chat when the creator has member-level project access" do
      # @spec QUESTION-EXPLORATION-014
      account = create(:account)
      owner = create(:user, account:)
      creator = create(:user, :viewer, account:)
      project = create(:project, account:, created_by: owner)
      create(:project_membership, :member, user: creator, project:)
      inbox_chat = create(:chat_session, account:, project:, created_by: creator, inbox_item_key: "clarifying_questions:1")

      sessions = described_class::Scope.new(creator, ChatSession).resolve

      expect(sessions).to contain_exactly(inbox_chat)
    end
  end
end
