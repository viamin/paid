# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::OpenChat do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account) }
  let(:questions) { [ "What is the expected behavior?", "Should this be behind a flag?" ] }
  let(:issue) do
    create(:issue, :needs_input, project: project, needs_input_questions: questions)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:issue_comments).and_return([])
  end

  describe ".call" do
    # @spec QUESTION-EXPLORATION-001
    it "creates the canonical linked chat under the issue's account with the generic title" do
      chat = described_class.call(issue: issue, user: user)

      expect(chat.account).to eq(account)
      expect(chat.created_by).to eq(user)
      expect(chat.project).to eq(project)
      expect(chat.clarifying_question_issue).to eq(issue)
      expect(chat.title).to eq("Clarifying questions")
    end

    # @spec QUESTION-EXPLORATION-001
    it "snapshots the pending questions into metadata and the system prompt" do
      chat = described_class.call(issue: issue, user: user)

      expect(chat.metadata["clarifying_question_issue_id"]).to eq(issue.id)
      expect(chat.metadata["clarifying_questions"]).to eq(questions)

      system_message = chat.messages.find_by(role: "system")
      expect(system_message.content).to include("Clarifying Questions for Issue ##{issue.github_number}")
      expect(system_message.content).to include("1. What is the expected behavior?")
      expect(system_message.content).to include("2. Should this be behind a flag?")
      expect(system_message.content).to include("submit_clarifying_answers")
    end

    it "resolves the questions before the insert so no GitHub call runs inside the open transaction" do
      load_open_transactions = nil
      allow(ClarifyingQuestions::Load).to receive(:call) do |**|
        load_open_transactions = ActiveRecord::Base.connection.open_transactions
        questions
      end
      baseline = ActiveRecord::Base.connection.open_transactions

      described_class.call(issue: issue, user: user)

      expect(load_open_transactions).to eq(baseline)
    end

    # @spec QUESTION-EXPLORATION-001
    it "reuses the existing active chat on subsequent opens" do
      first = described_class.call(issue: issue, user: user)
      second = described_class.call(issue: issue, user: user)

      expect(second.id).to eq(first.id)
      expect(ChatSession.where(clarifying_question_issue: issue).count).to eq(1)
    end

    # @spec QUESTION-EXPLORATION-001
    it "restores an archived linked chat instead of creating a new one" do
      first = described_class.call(issue: issue, user: user)
      first.update!(status: "archived")

      second = described_class.call(issue: issue, user: user)

      expect(second.id).to eq(first.id)
      expect(second.reload.status).to eq("active")
      expect(ChatSession.where(clarifying_question_issue: issue).count).to eq(1)
    end

    # @spec QUESTION-EXPLORATION-001
    it "converges on the concurrent winner when the unique index rejects a duplicate create" do
      allow(ChatSessions::Create).to receive(:call) do
        create(:chat_session, account: account, created_by: user, project: project,
          clarifying_question_issue: issue)
        raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
      end

      chat = described_class.call(issue: issue, user: user)

      expect(chat.clarifying_question_issue).to eq(issue)
      expect(ChatSession.where(clarifying_question_issue: issue).count).to eq(1)
      expect(ChatSessions::Create).to have_received(:call).once
    end
  end
end
