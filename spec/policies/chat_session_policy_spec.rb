# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessionPolicy do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:linked_session) do
    create(:chat_session, account: account, project: project,
      clarifying_question_issue: create(:issue, project: project))
  end

  # @spec QUESTION-EXPLORATION-007
  it "does not expose linked chats to account members without project membership" do
    create(:user, account: account)
    user = create(:user, :member, account: account)

    expect(described_class.new(user, linked_session)).not_to be_show
  end

  # @spec QUESTION-EXPLORATION-007
  it "permits project collaborators to view linked chats" do
    create(:user, account: account)
    user = create(:user, :viewer, account: account)
    user.add_role(:project_viewer, project)

    expect(described_class.new(user, linked_session)).to be_show
  end

  # @spec QUESTION-EXPLORATION-007
  it "limits account members to linked chats in their projects" do
    create(:user, account: account)
    user = create(:user, :member, account: account)
    visible_session = linked_session
    hidden_project = create(:project, account: account)
    hidden_session = create(:chat_session, account: account, project: hidden_project,
      clarifying_question_issue: create(:issue, project: hidden_project))
    user.add_role(:project_member, project)

    scope = described_class::Scope.new(user, ChatSession.all).resolve

    expect(scope).to include(visible_session)
    expect(scope).not_to include(hidden_session)
  end
end
