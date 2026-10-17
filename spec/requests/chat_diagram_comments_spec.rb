# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat diagram comments" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:chat_session) { create(:chat_session, account:, created_by: user) }
  let(:diagram) { create(:chat_diagram, chat_session:) }

  before { sign_in user }

  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-012
  it "records actor and selected text through the chat UI endpoint" do
    expect {
      post chat_session_chat_diagram_comments_path(chat_session, diagram), params: {
        body: "Can this retry?", element_id: "app"
      }
    }.to change(ChatDiagramComment, :count).by(1)

    comment = ChatDiagramComment.last
    expect(comment).to have_attributes(actor: user, question_key: diagram.question_key,
      element_context: "Application: The Paid application.")
  end

  # @spec QUESTION-EXPLORATION-006
  it "asks for clarification instead of retargeting a stale element" do
    post chat_session_chat_diagram_comments_path(chat_session, diagram), params: {
      body: "Can this retry?", element_id: "missing"
    }

    expect(response).to redirect_to(chat_session_path(chat_session))
    expect(flash[:alert]).to include("no longer available")
    expect(ChatDiagramComment).not_to exist
  end

  # @spec QUESTION-EXPLORATION-004
  it "limits comment creation per user and chat session" do
    allow(Rails.cache).to receive(:increment).and_return(ChatMessages::RateLimit::MAX_REQUESTS + 1)

    expect {
      post chat_session_chat_diagram_comments_path(chat_session, diagram), params: { body: "Can this retry?" }
    }.not_to change { diagram.comments.count }

    expect(response).to redirect_to(chat_session_path(chat_session))
  end
end
