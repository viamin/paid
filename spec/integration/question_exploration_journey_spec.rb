# frozen_string_literal: true

require "rails_helper"

# End-to-end exercise of the RDR-069 question-centered journey: a person opens
# an Inbox question, shares the conversation with a collaborator, explores it
# with a diagram and a comment, redirects the method, saves partial progress,
# reconnects after the conversation is archived, and posts the final answer.
#
# The individual steps have unit coverage; this file is the acceptance evidence
# that the shipped pieces compose into one person-visible outcome, and that the
# answer plus its human evidence survive superseded diagrams and an archive.
# @spec QUESTION-EXPLORATION-001
# @spec QUESTION-EXPLORATION-002
# @spec QUESTION-EXPLORATION-004
# @spec QUESTION-EXPLORATION-005
# @spec QUESTION-EXPLORATION-007
# @spec QUESTION-EXPLORATION-013
# @spec QUESTION-EXPLORATION-018
RSpec.describe "Question-centered exploration journey", type: :model do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:collaborator) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, question_exploration_enabled: true) }
  let(:issue) do
    create(:issue, :needs_input, project:, github_number: 101, title: "Inbox needs input",
      needs_input_questions: [ "How should authentication work?", "Should failures be behind a flag?" ])
      .tap { |created| create(:feature_intent_issue, feature_intent: feature, issue: created) }
  end
  let(:feature) { create(:feature_intent, project:, title: "Inbox redesign") }
  let(:github_client) { instance_double(GithubClient) }
  let(:chat) { ClarifyingQuestions::OpenChat.call(issue:, user: owner) }

  before do
    create(:project_membership, user: collaborator, project:)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(issue_comments: [], remove_label_from_issue: nil,
      add_comment: double(html_url: "https://github.com/test"))
  end

  # Journey steps, expressed once so each example composes them in order.

  # @spec QUESTION-EXPLORATION-003
  def present_credential_diagram(session)
    Tools::PresentChatDiagram.new(user: collaborator, session:).call(
      question_key: "how-should-authentication-work", question_title: "How should authentication work?",
      summary: "A browser exchanges credentials for a session.",
      text_equivalent: "The client sends credentials to the application, which creates a session.",
      description: {
        "elements" => [
          { "id" => "client", "label" => "Client", "description" => "The person using the application." },
          { "id" => "app", "label" => "Application", "description" => "The Paid application." }
        ],
        "relationships" => [ { "from" => "client", "to" => "app", "label" => "sends credentials" } ]
      }
    )
  end

  # The collaborator raises a question about one element of that diagram.
  # @spec QUESTION-EXPLORATION-004
  def comment_on_application(session)
    diagram_id = present_credential_diagram(session).fetch(:diagram).fetch(:id)
    ChatDiagrams::Comment.call(diagram: ChatDiagram.find(diagram_id), actor: collaborator,
      body: "Does this retry forever?", element_id: "app")
  end

  # The person redirects the method: a second aid supersedes the first rather
  # than forking a second conversation or a parallel diagram set.
  # @spec QUESTION-EXPLORATION-005
  def redirect_to_session_diagram(session)
    Tools::PresentChatDiagram.new(user: collaborator, session:).call(
      question_key: "how-should-authentication-work", question_title: "How should authentication work?",
      summary: "A session cookie carries the signed-in identity.",
      text_equivalent: "The application issues a signed session cookie after verifying credentials.",
      description: {
        "elements" => [
          { "id" => "app", "label" => "Application", "description" => "Verifies credentials." },
          { "id" => "cookie", "label" => "Session cookie", "description" => "Carries the signed-in identity." }
        ],
        "relationships" => [ { "from" => "app", "to" => "cookie", "label" => "issues" } ]
      }
    )
  end

  # A confirmed draft answer keeps its human context and posts nothing.
  # @spec QUESTION-EXPLORATION-002
  def save_draft_answer(session)
    Tools::SaveClarifyingAnswer.new(user: owner, session:).call(
      position: 1, answer: "Show the error inline.", confirmed: true,
      evidence_context: "Collaborator asked about retries on the Application element."
    )
  end

  # Reconnect: archiving releases the workspace, and reopening returns the same
  # conversation with its saved progress in place.
  # @spec QUESTION-EXPLORATION-013
  def reconnect(user = collaborator)
    ChatSessions::Archive.call(chat_session: chat)
    ClarifyingQuestions::OpenChat.call(issue:, user:).reload
  end

  describe "sharing the exploration" do
    it "hands the collaborator the same feature conversation and refuses an outsider" do
      shared = ClarifyingQuestions::OpenChat.call(issue:, user: collaborator)
      outsider = create(:user, :owner, account: create(:account))
      message = ChatMessage.new(chat_session: chat)

      aggregate_failures do
        expect(shared.id).to eq(chat.id)
        expect(chat).to have_attributes(feature_intent: feature, clarifying_question_issue: issue)
        expect(ChatMessagePolicy.new(collaborator, message)).to be_create
        expect(ChatMessagePolicy.new(outsider, message)).not_to be_create
      end
    end
  end

  describe "exploring with a diagram" do
    it "keeps the collaborator's comment intelligible on the element it was made against" do
      comment = comment_on_application(chat)

      aggregate_failures do
        expect(comment).to have_attributes(question_key: "how-should-authentication-work", element_id: "app",
          element_context: "Application: The Paid application.", actor: collaborator)
        expect(ChatSessions::BuildSystemPrompt.call(chat_session: chat)).to include("Does this retry forever?")
      end
    end

    it "supersedes the working diagram when the person redirects the method" do
      comment = comment_on_application(chat)
      redirect_to_session_diagram(chat)

      aggregate_failures do
        expect(ChatDiagram.where(chat_session: chat, current: true).count).to eq(1)
        expect(ChatDiagram.where(chat_session: chat, current: false)).to exist
        expect(comment.reload.element_context).to eq("Application: The Paid application.")
      end
    end
  end

  describe "saving partial progress" do
    it "keeps the answer with its human evidence and posts nothing yet" do
      save_draft_answer(chat)
      progress = issue.clarifying_question_progresses.find_by!(position: 1)

      aggregate_failures do
        expect(progress).to have_attributes(answer: "Show the error inline.", answered_by: owner,
          evidence_context: "Collaborator asked about retries on the Application element.")
        expect(github_client).not_to have_received(:add_comment)
        expect(issue.reload).to be_needs_input
      end
    end
  end

  describe "reconnecting after an archive" do
    it "restores the same conversation with the answer and its evidence intact" do
      save_draft_answer(chat)
      reopened = reconnect
      restored_prompt = ChatSessions::BuildSystemPrompt.call(chat_session: reopened)

      aggregate_failures do
        expect(reopened.id).to eq(chat.id)
        expect(reopened).to be_active
        expect(restored_prompt).to include("Saved draft answer: Show the error inline.")
        expect(restored_prompt).to include("Collaborator asked about retries on the Application element.")
      end
      expect(issue.clarifying_question_progresses.find_by!(position: 1).answer).to eq("Show the error inline.")
    end
  end

  describe "posting the final answer" do
    it "posts through the standard comment path and clears only this issue's needs-input state" do
      save_draft_answer(chat)
      reopened = reconnect

      Tools::SubmitClarifyingAnswers.new(user: owner, session: reopened).call(
        answers: [ "Show the error inline.", "Yes, behind a flag." ], confirmed: true
      )

      aggregate_failures do
        expect(github_client).to have_received(:add_comment).with(project.full_name, issue.github_number,
          a_string_including("Show the error inline.", "Yes, behind a flag."))
        expect(issue.reload).not_to be_needs_input
      end
    end

    it "leaves the answer intelligible after the temporary diagram source is released" do
      comment = comment_on_application(chat)
      save_draft_answer(chat)
      redirect_to_session_diagram(chat)
      superseded = ChatDiagram.where(chat_session: chat, current: false)

      aggregate_failures do
        expect(issue.clarifying_question_progresses.answered.pluck(:answer)).to include("Show the error inline.")
        expect(ChatDiagramComment.find(comment.id)).to have_attributes(
          question_key: "how-should-authentication-work", element_context: "Application: The Paid application."
        )
        expect(superseded.pluck(:description)).to all(eq({}))
        expect(superseded.pluck(:question_key)).to eq([ "how-should-authentication-work" ])
      end
    end
  end
end
