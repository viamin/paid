# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::Load, :no_db do
  def structured_scope_question(choice_type: nil)
    {
      "question" => "Which scope should ship first?",
      "choices" => [
        { "label" => "API", "detail" => "Ship the API first" },
        { "label" => "UI", "detail" => "Ship the UI first" }
      ],
      "recommendation" => "API",
      "evidence_references" => [ "app/controllers/api_controller.rb:1" ]
    }.tap { |question| question["choice_type"] = choice_type if choice_type }
  end

  let(:trusted_login) { "viamin" }
  let(:issue_body) { "Original issue body" }
  let(:github_client) { instance_double(GithubClient) }
  let(:project) do
    double(
      client: github_client,
      github_credential_present?: true,
      full_name: "paid/app",
      quiet_mode?: false
    )
  end
  let(:issue) do
    double(
      id: 42,
      body: issue_body,
      github_number: 1964,
      github_updated_at: 2.minutes.ago,
      needs_input_questions: nil,
      needs_input?: false
    )
  end
  let(:comment_body) do
    <<~COMMENT
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
      2. Should this be behind a flag?

      ## Current context
      - Some context
    COMMENT
  end
  let(:full_answers_body) do
    <<~COMMENT
      <!-- paid:clarifying-answers -->

      ## Clarifying question answers

      **Q1: What is the expected behavior?**
      **A1:** Use the wizard flow.

      **Q2: Should this be behind a flag?**
      **A2:** No, ship it directly.
    COMMENT
  end

  before do
    allow(github_client).to receive(:issue_comments).and_return([])
    allow(project).to receive(:trusted_github_user?) { |login| login == trusted_login }
    allow(project).to receive(:paid_bot_author?).and_return(false)
  end

  describe ".call" do
    context "when a quiet-mode description section carries the posted marker lines" do
      before do
        allow(project).to receive(:quiet_mode?).and_return(true)
      end

      let(:structured_question) { structured_scope_question }
      let(:digest) { ClarifyingQuestions::DescriptionSection.digest_for([ "Which scope should ship first?" ]) }
      let(:issue_body) do
        <<~BODY
          Original issue body

          <!-- paid:clarifying-questions -->
          ## Clarifying questions

          <!-- paid:clarifying-questions-digest:#{digest} -->
          1. Which scope should ship first?
             - ( ) API) Ship the API first
             - ( ) UI) Ship the UI first
          <!-- /paid:clarifying-questions -->
        BODY
      end
      let(:issue) do
        double(
          id: 42,
          body: issue_body,
          github_number: 1964,
          github_updated_at: 2.minutes.ago,
          needs_input_questions: [ structured_question ],
          needs_input?: true
        )
      end

      # @spec QUIET-MODE-011 @spec OPERATOR-INBOX-025
      it "reconciles the description channel with the stored structured payload" do
        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ structured_question ])
      end

      # @spec QUIET-MODE-011
      # The description is the editable questions channel in quiet mode: a
      # human edit that changes a choice marker while leaving the question
      # label untouched must render the edited choices, not the cached
      # structured record's.
      it "serves the description's edited choices when the labels are unchanged" do
        edited_body = issue_body.sub("- ( ) UI) Ship the UI first", "- ( ) CLI) Ship the CLI first")
        allow(issue).to receive(:body).and_return(edited_body)

        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "Which scope should ship first? - ( ) API) Ship the API first - ( ) CLI) Ship the CLI first" ])
      end

      it "treats a body answer to the structured set as complete and ingests it" do
        answered_body = issue_body + <<~BODY

          <!-- paid:clarifying-answers -->
          ## Clarifying question answers

          <!-- paid:clarifying-answers-digest:#{digest} -->
          **Q1: Which scope should ship first?**
          **A1:** API
          <!-- /paid:clarifying-answers -->
        BODY
        allow(issue).to receive(:body).and_return(answered_body)
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call).and_return(true)
        expect(ClarifyingQuestions::ClearNeedsInput).to receive(:call).with(project: project, issue: issue)

        expect(described_class.call(project: project, issue: issue)).to eq([])
        expect(ClarifyingQuestions::IngestAnswers).to have_received(:call).with(
          project: project,
          issue: issue,
          issue_body: answered_body
        )
      end
    end

    context "when the issue body already contains clarifying questions" do
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What should happen next?
        COMMENT
      end

      it "returns questions from the issue body" do
        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "What should happen next?" ])
      end

      it "only loads GitHub comments once to check for newer answers" do
        described_class.call(project: project, issue: issue)

        expect(github_client).to have_received(:issue_comments).once
      end

      it "falls back to body questions when GitHub comments cannot be loaded" do
        allow(github_client).to receive(:issue_comments).and_raise(GithubClient::Error, "GitHub unavailable")

        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "What should happen next?" ])
      end
    end

    context "when clarifying questions only exist in GitHub comments" do
      before do
        comment = double(body: comment_body, user: double(login: trusted_login))
        allow(github_client).to receive(:issue_comments).and_return([ comment ])
      end

      it "loads questions from the latest enhancement comment" do
        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([
          "What is the expected behavior?",
          "Should this be behind a flag?"
        ])
      end
    end

    context "when clarifying questions are persisted locally" do
      let(:issue) do
        double(
          id: 42,
          body: "Original issue body",
          github_number: 1964,
          github_updated_at: 2.minutes.ago,
          needs_input_questions: [ "Which scope should ship first?" ],
          needs_input?: true
        )
      end

      it "returns the persisted questions" do
        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "Which scope should ship first?" ])
      end

      it "returns persisted questions when GitHub comments cannot be loaded" do
        allow(github_client).to receive(:issue_comments).and_raise(GithubClient::Error, "GitHub unavailable")

        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "Which scope should ship first?" ])
      end

      it "prefers newer questions from GitHub comments" do
        comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )
        allow(github_client).to receive(:issue_comments).and_return([ comment ])

        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([
          "What is the expected behavior?",
          "Should this be behind a flag?"
        ])
      end

      # @spec OPERATOR-INBOX-025
      # The posted text is the contract: when the comment no longer carries
      # the stored payload's choice markers (a human edit removed them), the
      # posted text wins over the cached structured record so the inbox
      # cannot keep offering the removed choices.
      it "serves the comment text when its choice markers were removed" do
        structured_question = structured_scope_question
        allow(issue).to receive(:needs_input_questions).and_return([ structured_question ])
        comment = double(
          body: "<!-- paid:enhance-issue -->\n\n## Clarifying questions\n1. Which scope should ship first?",
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )
        allow(github_client).to receive(:issue_comments).and_return([ comment ])

        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "Which scope should ship first?" ])
      end

      it "preserves a structured choice payload when the GitHub comment includes its markers" do # @spec OPERATOR-INBOX-025
        structured_question = structured_scope_question(choice_type: "multi")
        allow(issue).to receive(:needs_input_questions).and_return([ structured_question ])
        comment = double(
          body: <<~COMMENT,
            <!-- paid:enhance-issue -->

            ## Clarifying questions
            1. Which scope should ship first?
               - [ ] API) Ship the API first
               - [ ] UI) Ship the UI first
          COMMENT
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )
        allow(github_client).to receive(:issue_comments).and_return([ comment ])

        expect(described_class.call(project: project, issue: issue)).to eq([ structured_question ])
      end
    end

    context "when the latest clarifying questions were already answered" do
      before do
        enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call)
      end

      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end

      it "reuses the already-loaded issue comments during ingestion" do
        described_class.call(project: project, issue: issue)

        expect(ClarifyingQuestions::IngestAnswers).to have_received(:call).with(
          project: project,
          issue: issue,
          issue_comments: kind_of(Array)
        )
        expect(github_client).to have_received(:issue_comments).once
      end

      it "reconciles posted choice markers before recognizing a structured question answer" do # @spec OPERATOR-INBOX-025
        structured_question = structured_scope_question
        allow(issue).to receive(:needs_input_questions).and_return([ structured_question ])
        enhancement_comment = double(
          body: <<~COMMENT,
            <!-- paid:enhance-issue -->

            ## Clarifying questions
            1. Which scope should ship first?
               - ( ) API) Ship the API first
               - ( ) UI) Ship the UI first
          COMMENT
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
        answers_comment = double(
          body: "<!-- paid:clarifying-answers -->\n\n**Q1: Which scope should ship first?**\n**A1:** API",
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )
        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, answers_comment ])

        expect(described_class.call(project:, issue:)).to eq([])
        expect(ClarifyingQuestions::IngestAnswers).to have_received(:call)
      end
    end

    context "when matching answers predate repeated clarifying questions" do
      before do
        original_enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 3.minutes.ago
        )
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
        repeated_enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([
          original_enhancement_comment,
          answers_comment,
          repeated_enhancement_comment
        ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call)
      end

      it "returns the latest questions instead of treating stale answers as current" do
        expect(described_class.call(project: project, issue: issue)).to eq([
          "What is the expected behavior?",
          "Should this be behind a flag?"
        ])
        expect(ClarifyingQuestions::IngestAnswers).not_to have_received(:call)
      end
    end

    context "when the issue body still contains questions after answers were posted" do
      let(:issue_body) { comment_body }

      before do
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call)
      end

      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when unrelated issue activity advanced github_updated_at after answers were posted" do
      let(:issue_body) { comment_body }
      let(:issue) do
        double(
          body: issue_body,
          github_number: 1964,
          github_updated_at: 30.seconds.ago
        )
      end

      before do
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call)
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
      end

      it "still treats the current questions as answered" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when the issue body questions changed after answers were posted" do
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What should happen when the redirect is invalid?
        COMMENT
      end

      before do
        answers_comment = double(
          body: <<~COMMENT,
            <!-- paid:clarifying-answers -->

            ## Clarifying question answers

            **Q1: What is the expected behavior?**
            **A1:** Use the wizard flow.
          COMMENT
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
      end

      it "returns the refreshed body questions" do
        expect(described_class.call(project: project, issue: issue)).to eq([
          "What should happen when the redirect is invalid?"
        ])
      end
    end

    context "when quiet mode was disabled after description answers were recorded" do
      let(:issue_body) do
        <<~COMMENT
          Original issue body

          <!-- paid:clarifying-questions -->
          ## Clarifying questions

          <!-- paid:clarifying-questions-digest:#{ClarifyingQuestions::DescriptionSection.digest_for([ "What was the original scope?" ])} -->
          1. What was the original scope?
          <!-- /paid:clarifying-questions -->

          <!-- paid:clarifying-answers -->
          ## Clarifying question answers

          <!-- paid:clarifying-answers-digest:#{ClarifyingQuestions::DescriptionSection.digest_for([ "What was the original scope?" ])} -->
          **Q1: What was the original scope?**
          **A1:** The old scope.
          <!-- /paid:clarifying-answers -->
        COMMENT
      end

      it "uses a newer enhancement comment instead of resolving stale description answers" do # @spec QUIET-MODE-011
        enhancement_comment = double(
          body: <<~COMMENT,
            <!-- paid:enhance-issue -->

            ## Clarifying questions
            1. What is the current scope?
          COMMENT
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )
        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment ])
        expect(ClarifyingQuestions::IngestAnswers).not_to receive(:call)

        expect(described_class.call(project: project, issue: issue)).to eq([ "What is the current scope?" ])
      end

      it "does not reopen answered description questions without an enhancement comment" do # @spec QUIET-MODE-011
        allow(github_client).to receive(:issue_comments).and_return([])
        expect(ClarifyingQuestions::IngestAnswers).not_to receive(:call)

        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when quiet-mode answer digest matches but answer pairs are missing" do
      let(:issue_body) do
        questions = [ "What should happen next?" ]
        digest = ClarifyingQuestions::DescriptionSection.digest_for(questions)

        <<~COMMENT
          <!-- paid:clarifying-questions -->
          ## Clarifying questions

          <!-- paid:clarifying-questions-digest:#{digest} -->
          1. What should happen next?
          <!-- /paid:clarifying-questions -->

          <!-- paid:clarifying-answers -->
          ## Clarifying question answers

          <!-- paid:clarifying-answers-digest:#{digest} -->
          <!-- /paid:clarifying-answers -->
        COMMENT
      end

      before { allow(project).to receive(:quiet_mode?).and_return(true) }

      it "keeps the questions pending" do # @spec QUIET-MODE-011
        expect(ClarifyingQuestions::ClearNeedsInput).not_to receive(:call)

        expect(described_class.call(project: project, issue: issue)).to eq([ "What should happen next?" ])
      end
    end

    context "when only an answers comment remains" do
      before do
        answers_comment = double(
          body: <<~COMMENT,
            <!-- paid:clarifying-answers -->

            ## Clarifying question answers

            **Q1: What is the expected behavior?**
            **A1:** Use the wizard flow.
          COMMENT
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
      end

      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when only an untrusted answers marker exists" do
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior?
        COMMENT
      end

      before do
        answers_comment = double(
          body: <<~COMMENT,
            <!-- paid:clarifying-answers -->

            ## Clarifying question answers

            **Q1: What is the expected behavior?**
            **A1:** Use the wizard flow.
          COMMENT
          user: double(login: "attacker"),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
      end

      it "ignores the spoofed answers marker" do
        expect(described_class.call(project: project, issue: issue)).to eq([ "What is the expected behavior?" ])
      end
    end

    context "when the answers marker is authored by the project's GitHub App bot" do
      let(:bot_login) { "paid-agents[bot]" }
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior?
        COMMENT
      end

      before do
        allow(project).to receive(:paid_bot_author?) { |login| login == bot_login }

        answers_comment = double(
          body: <<~COMMENT,
            <!-- paid:clarifying-answers -->

            ## Clarifying question answers

            **Q1: What is the expected behavior?**
            **A1:** Use the wizard flow.
          COMMENT
          user: double(login: bot_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call).and_return(true)
      end

      it "treats the questions as answered (the bot answer comment is honored)" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when the questions have been answered" do
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior?
        COMMENT
      end

      before do
        answers_comment = double(
          body: <<~COMMENT,
            <!-- paid:clarifying-answers -->

            ## Clarifying question answers

            **Q1: What is the expected behavior?**
            **A1:** Use the wizard flow.
          COMMENT
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )
        allow(github_client).to receive(:issue_comments).and_return([ answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call).and_return(true)
      end

      it "self-heals the stale needs-input marker so the button disappears" do
        expect(ClarifyingQuestions::ClearNeedsInput).to receive(:call).with(project: project, issue: issue)

        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when no clarifying questions are available" do
      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when answer ingestion hits a database error" do
      let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

      before do
        enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(Issue.new))
        allow(Rails).to receive(:logger).and_return(logger)
      end

      it "logs and still returns an empty array" do
        expect(ClarifyingQuestions::ClearNeedsInput).not_to receive(:call)

        expect(described_class.call(project: project, issue: issue)).to eq([])

        expect(logger).to have_received(:warn).with(
          hash_including(
            message: "clarifying_questions.ingest_answers_failed",
            issue_id: 42
          )
        )
      end
    end

    context "when answer ingestion returns nil (no qa pairs ingested)" do
      before do
        enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call).and_return(nil)
      end

      it "does not clear needs_input so the issue stays blocked" do
        expect(ClarifyingQuestions::ClearNeedsInput).not_to receive(:call)

        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when answer ingestion raises a non-database error" do
      before do
        enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
        answers_comment = double(
          body: full_answers_body,
          user: double(login: trusted_login),
          created_at: 1.minute.ago
        )

        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call).and_raise(ArgumentError, "bug")
      end

      it "surfaces the error" do
        expect { described_class.call(project: project, issue: issue) }
          .to raise_error(ArgumentError, "bug")
      end
    end

    context "when GitHub access is not configured" do
      let(:project) do
        double(
          github_credential_present?: false
        )
      end
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What should happen next?
        COMMENT
      end

      it "returns questions from the issue body" do
        expect(described_class.call(project: project, issue: issue)).to eq([ "What should happen next?" ])
      end
    end
  end

  # @spec OPERATOR-INBOX-011
  describe "#context_markdown" do
    let(:context_loaded_load) { described_class.new(project: project, issue: issue) }

    it "returns the Current Context section + clarifying preamble from the latest enhancement comment" do
      body = <<~COMMENT
        <!-- paid:enhance-issue -->

        ## Clarifying questions

        Need a call before implementation.

        1. What is the expected behavior?
        2. Should this be behind a flag?

        ## Current context
        - The repo already has a flag toggle wired up.
      COMMENT
      comment = double(body: body, user: double(login: trusted_login))
      allow(github_client).to receive(:issue_comments).and_return([ comment ])

      expect(context_loaded_load.context_markdown).to eq(
        "Need a call before implementation.\n\n" \
        "- The repo already has a flag toggle wired up."
      )
    end

    # @spec QUIET-MODE-011
    it "returns description prose without rendering the quiet-mode digest" do
      allow(project).to receive(:quiet_mode?).and_return(true)
      allow(issue).to receive(:body).and_return(<<~BODY)
        Original issue body.

        The agent needs the rollout scope before implementation.

        <!-- paid:clarifying-questions -->
        ## Clarifying questions

        <!-- paid:clarifying-questions-digest:abc12345 -->
        1. What is the original scope?
        <!-- /paid:clarifying-questions -->
      BODY

      expect(context_loaded_load.context_markdown).to eq(
        "Original issue body.\n\nThe agent needs the rollout scope before implementation."
      )
    end

    it "returns nil when the latest enhancement comment has no recoverable context" do
      comment_body_without_context = <<~COMMENT
        <!-- paid:enhance-issue -->

        ## Clarifying questions
        1. What is the expected behavior?
      COMMENT
      comment = double(body: comment_body_without_context, user: double(login: trusted_login))
      allow(github_client).to receive(:issue_comments).and_return([ comment ])

      expect(context_loaded_load.context_markdown).to be_nil
    end

    it "returns nil when GitHub credentials are missing" do
      credentialless = double(github_credential_present?: false, quiet_mode?: false)
      load = described_class.new(project: credentialless, issue: issue)

      expect(load.context_markdown).to be_nil
    end

    it "returns nil when no enhancement comment is fetchable" do
      allow(github_client).to receive(:issue_comments).and_return([])

      expect(context_loaded_load.context_markdown).to be_nil
    end

    it "reuses the cached issue_comments list so a second GitHub API call is not made" do
      comment = double(body: comment_body, user: double(login: trusted_login))
      allow(github_client).to receive(:issue_comments).and_return([ comment ])

      context_loaded_load.context_markdown
      context_loaded_load.context_markdown

      expect(github_client).to have_received(:issue_comments).once
    end

    it "swallows transient GitHub errors instead of raising so the inbox can render" do
      allow(github_client).to receive(:issue_comments).and_raise(GithubClient::Error, "GitHub unavailable")

      expect(context_loaded_load.context_markdown).to be_nil
    end
  end
end
