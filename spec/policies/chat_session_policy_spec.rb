# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessionPolicy do
  describe "#destroy?" do
    it "permits the interactive inbox chat creator with member-level project access" do
      # @spec QUESTION-EXPLORATION-014
      account = create(:account)
      owner = create(:user, account:)
      creator = create(:user, :viewer, account:)
      project = create(:project, account:, created_by: owner)
      create(:project_membership, :member, user: creator, project:)
      inbox_chat = create(:chat_session, account:, project:, created_by: creator, inbox_item_key: "clarifying_questions:1")

      expect(described_class.new(creator, inbox_chat)).to be_destroy
    end
  end

  describe "#unarchive?" do
    it "does not permit unarchiving an interactive inbox chat" do
      # @spec QUESTION-EXPLORATION-001
      account = create(:account)
      user = create(:user, :owner, account:)
      project = create(:project, account:, created_by: user)
      inbox_chat = create(:chat_session, :archived, account:, project:, created_by: user, inbox_item_key: "clarifying_questions:1")

      expect(described_class.new(user, inbox_chat)).not_to be_unarchive
    end
  end

  describe "linked chats" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account:) }
    let(:linked_session) do
      create(:chat_session, account:, project:, clarifying_question_issue: create(:issue, project:))
    end

    # @spec QUESTION-EXPLORATION-007
    it "does not expose linked chats to account members without project membership" do
      create(:user, account:)
      user = create(:user, :member, account:)

      expect(described_class.new(user, linked_session)).not_to be_show
    end

    # @spec QUESTION-EXPLORATION-007
    it "permits project collaborators to view linked chats" do
      create(:user, account:)
      user = create(:user, :viewer, account:)
      user.add_role(:project_viewer, project)

      expect(described_class.new(user, linked_session)).to be_show
    end
  end

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

      expect(described_class::Scope.new(creator, ChatSession).resolve).to contain_exactly(inbox_chat)
    end

    it "limits account members to linked chats in their projects" do
      # @spec QUESTION-EXPLORATION-007
      account = create(:account)
      project = create(:project, account:)
      create(:user, account:)
      user = create(:user, :member, account:)
      visible_session = create(:chat_session, account:, project:, clarifying_question_issue: create(:issue, project:))
      hidden_project = create(:project, account:)
      hidden_session = create(:chat_session, account:, project: hidden_project, clarifying_question_issue: create(:issue, project: hidden_project))
      user.add_role(:project_member, project)

      scope = described_class::Scope.new(user, ChatSession.all).resolve

      expect(scope).to include(visible_session)
      expect(scope).not_to include(hidden_session)
    end
  end
end
