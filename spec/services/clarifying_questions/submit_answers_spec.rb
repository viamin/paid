# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::SubmitAnswers, :no_db do
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
      github_number: 1964
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
        allow(project).to receive(:github_token).and_return(nil)
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
  end
end
