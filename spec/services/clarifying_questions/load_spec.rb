# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::Load, :no_db do
  let(:trusted_login) { "viamin" }
  let(:issue_body) { "Original issue body" }
  let(:github_client) { instance_double(GithubClient) }
  let(:github_token) { double(client: github_client) }
  let(:project) do
    double(
      github_token: github_token,
      full_name: "paid/app"
    )
  end
  let(:issue) do
    double(
      body: issue_body,
      github_number: 1964,
      github_updated_at: 2.minutes.ago
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

  before do
    allow(github_client).to receive(:issue_comments).and_return([])
    allow(project).to receive(:trusted_github_user?) { |login| login == trusted_login }
  end

  describe ".call" do
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

    context "when the latest clarifying questions were already answered" do
      before do
        enhancement_comment = double(
          body: comment_body,
          user: double(login: trusted_login),
          created_at: 2.minutes.ago
        )
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

        allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, answers_comment ])
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call)
      end

      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when the issue body still contains questions after answers were posted" do
      let(:issue_body) { comment_body }

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
        allow(ClarifyingQuestions::IngestAnswers).to receive(:call)
      end

      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when the issue body was updated after answers were posted" do
      let(:issue_body) { comment_body }
      let(:issue) do
        double(
          body: issue_body,
          github_number: 1964,
          github_updated_at: 30.seconds.ago
        )
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
          "What is the expected behavior?",
          "Should this be behind a flag?"
        ])
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

    context "when no clarifying questions are available" do
      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end

    context "when GitHub access is not configured" do
      let(:project) do
        double(
          github_token: nil
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
end
