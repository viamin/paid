# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::SubmitAnswers, :no_db do
  let(:github_client) { instance_double(GithubClient) }
  let(:project) do
    double(
      client: github_client,
      full_name: "paid/app"
    )
  end
  let(:issue) do
    double(
      github_number: 1964,
      needs_input?: false
    )
  end

  before do
    allow(github_client).to receive(:add_comment).and_return(double(html_url: "https://github.com/test"))
  end

  describe ".call" do
    context "when all questions are answered" do
      it "posts a comment with formatted answers to the GitHub issue" do
        questions_and_answers = [
          { question: "What is the expected behavior?", answer: "Return a 404 error" },
          { question: "Should this be behind a flag?", answer: "Yes, use feature flag X" }
        ]

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers
        )

        expect(github_client).to have_received(:add_comment).with(
          project.full_name,
          issue.github_number,
          a_string_matching(/Clarifying question answers/)
        )
      end

      it "includes the paid clarifying-answers marker" do
        questions_and_answers = [
          { question: "Q1?", answer: "A1" }
        ]

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers
        )

        expect(github_client).to have_received(:add_comment).with(
          anything, anything,
          a_string_matching(/<!-- paid:clarifying-answers -->/)
        )
      end

      it "formats questions and answers with Q/A labels" do
        questions_and_answers = [
          { question: "What is X?", answer: "X is Y" }
        ]

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers
        )

        expect(github_client).to have_received(:add_comment).with(
          anything, anything,
          a_string_matching(/\*\*Q1: What is X\?\*\*/)
            .and(a_string_matching(/\*\*A1:\*\* X is Y/))
        )
      end
    end

    context "when some answers are blank" do
      it "raises ArgumentError" do
        questions_and_answers = [
          { question: "Q1?", answer: "A1" },
          { question: "Q2?", answer: "" }
        ]

        expect {
          described_class.call(
            project: project,
            issue: issue,
            questions_and_answers: questions_and_answers
          )
        }.to raise_error(ArgumentError, /All questions must be answered/)
      end

      it "does not post a comment" do
        questions_and_answers = [
          { question: "Q1?", answer: "" }
        ]

        expect {
          described_class.call(
            project: project,
            issue: issue,
            questions_and_answers: questions_and_answers
          )
        }.to raise_error(ArgumentError)

        expect(github_client).not_to have_received(:add_comment)
      end
    end

    context "when there are no questions to answer" do
      it "raises ArgumentError" do
        expect {
          described_class.call(
            project: project,
            issue: issue,
            questions_and_answers: []
          )
        }.to raise_error(ArgumentError, /No clarifying questions found/)
      end
    end

    context "when GitHub access is not configured" do
      before do
        allow(project).to receive(:client).and_return(nil)
      end

      it "raises ArgumentError before attempting to post" do
        expect {
          described_class.call(
            project: project,
            issue: issue,
            questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
          )
        }.to raise_error(ArgumentError, /GitHub access is not configured/)

        expect(github_client).not_to have_received(:add_comment)
      end
    end

    context "when the issue is awaiting input" do
      let(:issue) do
        double(
          github_number: 1964,
          needs_input?: true,
          has_label?: true,
          labels: [ "paid-needs-input", "P2" ]
        )
      end

      before do
        allow(project).to receive(:enhance_issue_needs_input_label_name).and_return("paid-needs-input")
        allow(github_client).to receive(:remove_label_from_issue)
        allow(issue).to receive(:update!)
      end

      it "removes the needs-input label on GitHub after posting answers" do
        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
        )

        expect(github_client).to have_received(:remove_label_from_issue).with(
          project.full_name, issue.github_number, "paid-needs-input"
        )
      end

      it "resets paid_state and drops the label locally so the button disappears" do
        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
        )

        expect(issue).to have_received(:update!).with(
          paid_state: "new", labels: [ "P2" ], needs_input_questions: nil
        )
      end

      it "still clears state when GitHub label removal fails" do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error.new("boom"))

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
        )

        expect(issue).to have_received(:update!).with(
          paid_state: "new", labels: [ "P2" ], needs_input_questions: nil
        )
      end
    end
  end
end
