# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SubmitClarifyingAnswers do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account: account) }
  let(:project) { create(:project, account: account) }
  let(:questions) { [ "What is the expected behavior?", "Should this be behind a flag?" ] }
  let(:issue) do
    create(:issue, :needs_input, project: project, needs_input_questions: questions)
  end
  let(:session) do
    create(:chat_session, account: account, created_by: user, project: project,
      clarifying_question_issue: issue)
  end
  let(:tool) { described_class.new(user:, session:) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      issue_comments: [],
      add_comment: double(html_url: "https://github.com/test"),
      remove_label_from_issue: nil
    )
  end

  describe ".available_for_chat?" do
    it "is available for an authorized user when the chat is linked" do
      expect(described_class).to be_available_for_chat(user: user, session: session)
    end

    it "is not available when the chat has no linked clarifying-question issue" do
      unlinked = create(:chat_session, account: account, created_by: user, project: project)

      expect(described_class).not_to be_available_for_chat(user: user, session: unlinked)
    end

    it "is not available to a user who cannot update the project" do
      viewer = create(:user, :viewer, account: account)

      expect(described_class).not_to be_available_for_chat(user: viewer, session: session)
    end
  end

  describe "#call" do
    # @spec CHAT-TOOL-CONFIRMATION-001
    it "raises when not confirmed" do
      expect do
        tool.call(answers: %w[A B], confirmed: false)
      end.to raise_error(ArgumentError, /Confirmation required/)

      expect(github_client).not_to have_received(:add_comment)
    end

    it "raises when the chat is not linked to clarifying questions" do
      unlinked = create(:chat_session, account: account, created_by: user, project: project)

      expect do
        described_class.new(user: user, session: unlinked).call(answers: %w[A B], confirmed: true)
      end.to raise_error(ArgumentError, /not linked to clarifying questions/)
    end

    # @spec QUESTION-EXPLORATION-002
    it "raises when the answers do not cover every pending question" do
      expect do
        tool.call(answers: [ "Only one" ], confirmed: true)
      end.to raise_error(ArgumentError, /Answer every pending question before posting/)

      expect(github_client).not_to have_received(:add_comment)
    end

    # @spec QUESTION-EXPLORATION-002
    it "posts the ordered answers through the standard answer path and clears the inbox item" do
      result = tool.call(answers: [ "X is a feature", "Yes, by default" ], confirmed: true)

      expect(github_client).to have_received(:add_comment).with(
        project.full_name,
        issue.github_number,
        a_string_including("**Q1: What is the expected behavior?**")
          .and(a_string_including("**A1:** X is a feature"))
          .and(a_string_including("**A2:** Yes, by default"))
      )
      expect(github_client).to have_received(:remove_label_from_issue).with(
        project.full_name, issue.github_number, project.enhance_issue_needs_input_label_name
      )
      expect(issue.reload.paid_state).to eq("new")
      expect(result).to eq(posted: true, issue_id: issue.id, issue_number: issue.github_number)
    end

    it "rejects a user who cannot update the project" do
      member = create(:user, :member, account: account)

      expect do
        described_class.new(user: member, session: session).call(answers: %w[A B], confirmed: true)
      end.to raise_error(Pundit::NotAuthorizedError)

      expect(github_client).not_to have_received(:add_comment)
    end
  end
end
