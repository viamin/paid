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
    it "creates the canonical linked chat under the issue's account with its repository and number" do
      chat = described_class.call(issue: issue, user: user)

      expect(chat.account).to eq(account)
      expect(chat.created_by).to eq(user)
      expect(chat.project).to eq(project)
      expect(chat.clarifying_question_issue).to eq(issue)
      expect(chat.title).to eq("Clarifying questions for #{project.full_name}##{issue.github_number}")
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
    it "updates a reused chat to the title identifying its linked issue" do
      chat = create(:chat_session, account: account, created_by: user, project: project,
        clarifying_question_issue: issue, title: "Clarifying questions")

      reused_chat = described_class.call(issue: issue, user: user)

      expect(reused_chat).to eq(chat)
      expect(reused_chat.reload.title).to eq("Clarifying questions for #{project.full_name}##{issue.github_number}")
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

  describe "question exploration rollout" do
    let(:exploration_project) { create(:project, account: account, question_exploration_enabled: true) }
    let(:feature) { create(:feature_intent, project: exploration_project, title: "Inbox redesign") }
    let(:feature_issue) do
      issue = create(:issue, :needs_input, project: exploration_project, github_number: 101,
        needs_input_questions: questions)
      create(:feature_intent_issue, feature_intent: feature, issue: issue)
      issue
    end

    before do
      allow(github_client).to receive(:issue_comments).and_return([])
    end

    describe "standalone issues" do
      let(:standalone_issue) do
        create(:issue, :needs_input, project: exploration_project, needs_input_questions: questions)
      end

      # @spec QUESTION-EXPLORATION-018
      it "keeps a per-issue conversation separate from other issues" do
        other = create(:issue, :needs_input, project: exploration_project, needs_input_questions: questions)

        chat = described_class.call(issue: standalone_issue, user: user)
        other_chat = described_class.call(issue: other, user: user)

        expect(chat.clarifying_question_issue).to eq(standalone_issue)
        expect(other_chat.id).not_to eq(chat.id)
        expect(ChatSession.where(clarifying_question_issue: standalone_issue).count).to eq(1)
      end
    end

    describe "feature conversations" do
      # @spec QUESTION-EXPLORATION-018
      it "creates one conversation linked to the feature and its opening issue" do
        chat = described_class.call(issue: feature_issue, user: user)

        expect(chat.feature_intent).to eq(feature)
        expect(chat.clarifying_question_issue).to eq(feature_issue)
        expect(chat.project).to eq(exploration_project)
        expect(chat.title).to eq("Feature exploration for #{exploration_project.full_name}: #{feature.title}")
        expect(chat.metadata["exploration_focus"]).to include(
          "issue_id" => feature_issue.id, "focused_by_id" => user.id
        )
      end

      it "renders the feature context and focused questions in the system prompt" do
        chat = described_class.call(issue: feature_issue, user: user)

        system_message = chat.messages.find_by(role: "system")
        expect(system_message.content).to include("Feature Conversation: #{feature.title}")
        expect(system_message.content).to include("Clarifying Questions for Issue ##{feature_issue.github_number}")
        expect(system_message.content).to include("1. What is the expected behavior?")
      end

      # @spec QUESTION-EXPLORATION-018
      it "reuses the feature conversation from a related feature issue and focuses it there" do
        second_issue = create(:issue, :needs_input, project: exploration_project, github_number: 102,
          needs_input_questions: [ "Which storage backend?" ])
        create(:feature_intent_issue, feature_intent: feature, issue: second_issue)

        first = described_class.call(issue: feature_issue, user: user)
        second = described_class.call(issue: second_issue, user: user)

        expect(second.id).to eq(first.id)
        expect(second.reload.clarifying_question_issue).to eq(feature_issue)
        expect(second.reload.feature_intent).to eq(feature)
        expect(second.metadata["exploration_focus"]).to include("issue_id" => second_issue.id)
        expect(second.metadata["clarifying_questions"]).to eq([ "Which storage backend?" ])
      end

      # @spec QUESTION-EXPLORATION-018
      it "announces a focus change in the transcript without repointing linkage" do
        second_issue = create(:issue, :needs_input, project: exploration_project, github_number: 102,
          needs_input_questions: [ "Which storage backend?" ])
        create(:feature_intent_issue, feature_intent: feature, issue: second_issue)

        chat = described_class.call(issue: feature_issue, user: user)
        expect {
          described_class.call(issue: second_issue, user: user)
        }.to change { chat.messages.where(role: "system").count }.by(1)

        notice = chat.messages.where(role: "system").order(:id).last
        expect(notice.content).to include("##{second_issue.github_number}")
        expect(notice.content).to include("Which storage backend?")
        expect(chat.reload.clarifying_question_issue).to eq(feature_issue)
      end

      # @spec QUESTION-EXPLORATION-018
      it "does not append a focus notice when the focused issue is reopened" do
        chat = described_class.call(issue: feature_issue, user: user)

        expect {
          described_class.call(issue: feature_issue, user: user)
        }.not_to change { chat.messages.where(role: "system").count }
      end

      # @spec QUESTION-EXPLORATION-018
      it "keeps unrelated projects on separate conversations" do
        other_project = create(:project, account: account, question_exploration_enabled: true)
        other_feature = create(:feature_intent, project: other_project)
        other_issue = create(:issue, :needs_input, project: other_project, needs_input_questions: questions)
        create(:feature_intent_issue, feature_intent: other_feature, issue: other_issue)

        chat = described_class.call(issue: feature_issue, user: user)
        other_chat = described_class.call(issue: other_issue, user: user)

        expect(other_chat.id).not_to eq(chat.id)
        expect(other_chat.feature_intent).to eq(other_feature)
      end

      # @spec QUESTION-EXPLORATION-018
      it "restores an archived feature conversation instead of creating a new one" do
        chat = described_class.call(issue: feature_issue, user: user)
        chat.update!(status: "archived")

        restored = described_class.call(issue: feature_issue, user: user)

        expect(restored.id).to eq(chat.id)
        expect(restored.reload.status).to eq("active")
        expect(ChatSession.where(feature_intent: feature).count).to eq(1)
      end

      # @spec QUESTION-EXPLORATION-018
      it "adopts a pre-existing per-issue chat for a feature issue instead of forking context" do
        legacy = create(:chat_session, account: account, created_by: user, project: exploration_project,
          clarifying_question_issue: feature_issue,
          metadata: { "clarifying_questions" => questions },
          title: "Clarifying questions")

        chat = described_class.call(issue: feature_issue, user: user)

        expect(chat.id).to eq(legacy.id)
        expect(chat.reload.feature_intent).to eq(feature)
        expect(chat.reload.clarifying_question_issue).to eq(feature_issue)
        expect(ChatSession.where(clarifying_question_issue: feature_issue).count).to eq(1)
      end

      # @spec QUESTION-EXPLORATION-018
      it "adopts a per-issue chat linked to another issue of the same feature" do
        second_issue = create(:issue, :needs_input, project: exploration_project, github_number: 102,
          needs_input_questions: [ "Which storage backend?" ])
        create(:feature_intent_issue, feature_intent: feature, issue: second_issue)
        legacy = create(:chat_session, account: account, created_by: user, project: exploration_project,
          clarifying_question_issue: second_issue,
          metadata: { "clarifying_questions" => [ "Which storage backend?" ] })

        chat = described_class.call(issue: feature_issue, user: user)

        expect(chat.id).to eq(legacy.id)
        expect(chat.reload.feature_intent).to eq(feature)
        expect(chat.metadata["exploration_focus"]).to include("issue_id" => feature_issue.id)
      end

      it "adopts a legacy chat whose metadata snapshot is missing entirely" do
        legacy = create(:chat_session, account: account, created_by: user, project: exploration_project,
          clarifying_question_issue: feature_issue)
        legacy.update_columns(metadata: nil)

        chat = described_class.call(issue: feature_issue, user: user)

        expect(chat.id).to eq(legacy.id)
        expect(chat.reload.feature_intent).to eq(feature)
        expect(chat.metadata["exploration_focus"]).to include("issue_id" => feature_issue.id)
        expect(chat.metadata["clarifying_questions"]).to eq(questions)
      end

      it "resolves focus questions outside any open transaction" do
        described_class.call(issue: feature_issue, user: user)
        second_issue = create(:issue, :needs_input, project: exploration_project, github_number: 102,
          needs_input_questions: [ "Which storage backend?" ])
        create(:feature_intent_issue, feature_intent: feature, issue: second_issue)

        load_open_transactions = nil
        allow(ClarifyingQuestions::Load).to receive(:call) do |**|
          load_open_transactions = ActiveRecord::Base.connection.open_transactions
          [ "Which storage backend?" ]
        end
        baseline = ActiveRecord::Base.connection.open_transactions

        described_class.call(issue: second_issue, user: user)

        expect(load_open_transactions).to eq(baseline)
      end

      # @spec QUESTION-EXPLORATION-019
      it "does not adopt a personal chat when opening the feature conversation" do
        personal = create(:chat_session, account: account, created_by: user, project: exploration_project)

        chat = described_class.call(issue: feature_issue, user: user)

        expect(chat.id).not_to eq(personal.id)
        expect(personal.reload.feature_intent).to be_nil
        expect(personal.reload.project_scoped_exploration?).to be(false)
      end

      it "converges concurrent feature opens on one conversation when the unique index rejects a duplicate" do
        allow(ChatSessions::Create).to receive(:call) do
          create(:chat_session, account: account, created_by: user, project: exploration_project,
            clarifying_question_issue: feature_issue, feature_intent: feature)
          raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
        end

        chat = described_class.call(issue: feature_issue, user: user)

        expect(chat.feature_intent).to eq(feature)
        expect(ChatSession.where(feature_intent: feature).count).to eq(1)
      end
    end

    describe "disabling exploration after use" do
      # @spec QUESTION-EXPLORATION-018
      it "preserves the feature conversation and its progress while legacy opens stop selecting it" do
        chat = described_class.call(issue: feature_issue, user: user)
        ClarifyingQuestions::SaveProgress.call(
          chat_session: chat, position: 1, answer: "Ship it", actor: user
        )
        exploration_project.update!(question_exploration_enabled: false)

        reopened = described_class.call(issue: feature_issue, user: user)

        expect(reopened.id).to eq(chat.id)
        expect(reopened.reload.feature_intent).to eq(feature)
        expect(
          ClarifyingQuestionProgress.where(issue: feature_issue, position: 1).first&.answer
        ).to eq("Ship it")
      end
    end

    describe "projects that never enabled exploration" do
      let(:plain_issue) { create(:issue, :needs_input, project: project, needs_input_questions: questions) }

      before do
        create(:feature_intent_issue, feature_intent: create(:feature_intent, project: project), issue: plain_issue)
      end

      # @spec QUESTION-EXPLORATION-018
      it "keeps the legacy per-issue conversation" do
        chat = described_class.call(issue: plain_issue, user: user)

        expect(chat.feature_intent).to be_nil
        expect(chat.clarifying_question_issue).to eq(plain_issue)
        expect(chat.title).to eq("Clarifying questions for #{project.full_name}##{plain_issue.github_number}")
      end
    end
  end
end
