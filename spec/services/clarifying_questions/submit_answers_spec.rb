# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::SubmitAnswers, :no_db do
  let(:github_client) { instance_double(GithubClient) }
  let(:project) do
    double(
      client: github_client,
      full_name: "paid/app",
      quiet_mode?: false
    )
  end
  let(:issue) do
    double(
      github_number: 1964,
      needs_input?: false,
      body: "Human-written issue context"
    )
  end

  before do
    allow(github_client).to receive(:add_comment).and_return(double(html_url: "https://github.com/test"))
  end

  def remote_body(content, questions = [ "Q1?" ])
    ClarifyingQuestions::DescriptionSection.replace_questions_section(body: content, questions: questions)
  end

  def awaiting_input_issue
    double(
      github_number: 1964,
      needs_input?: true,
      has_label?: true,
      labels: [ "paid-needs-input" ],
      body: "Stale local description"
    )
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

    context "when quiet mode is enabled" do
      before { allow(project).to receive(:quiet_mode?).and_return(true) }

      it "writes answers into the description without posting a comment" do # @spec QUIET-MODE-010
        allow(github_client).to receive(:issue).and_return(Struct.new(:body).new(remote_body("Human-written issue context")))
        allow(github_client).to receive(:update_issue)
        allow(issue).to receive(:update!)

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
        )

        expect(github_client).to have_received(:update_issue).with(
          project.full_name,
          issue.github_number,
          body: a_string_including(
            "Human-written issue context",
            "<!-- paid:clarifying-answers -->",
            "**Q1: Q1?**",
            "**A1:** A1"
          )
        )
        expect(github_client).not_to have_received(:add_comment)
      end

      it "preserves a human edit made after the issue was last synced" do # @spec QUIET-MODE-010
        allow(github_client).to receive(:issue).and_return(Struct.new(:body).new(remote_body("Human-edited remote description")))
        allow(github_client).to receive(:update_issue)
        allow(issue).to receive(:update!)

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
        )

        expect(github_client).to have_received(:update_issue).with(
          project.full_name,
          issue.github_number,
          body: a_string_including("Human-edited remote description", "<!-- paid:clarifying-answers -->")
        )
      end

      it "rebuilds answers from a human edit that arrives before the write" do # @spec QUIET-MODE-010
        first_body = Struct.new(:body).new(remote_body("First human edit"))
        second_body = Struct.new(:body).new(remote_body("Second human edit"))
        allow(github_client).to receive(:issue).and_return(first_body, second_body)
        updated_bodies = []
        allow(github_client).to receive(:update_issue) do |_repo, _number, body:|
          updated_bodies << body
        end
        allow(issue).to receive(:update!)

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: [ { question: "Q1?", answer: "A1" } ]
        )

        expect(updated_bodies).to contain_exactly(a_string_including("Second human edit"))
      end

      it "rejects answers when the remote questions changed before submission" do # @spec QUIET-MODE-010 @spec QUIET-MODE-011
        replacement_questions_body = remote_body("", [ "What should Q2 do?" ])
        pending_issue = awaiting_input_issue
        allow(project).to receive(:enhance_issue_needs_input_label_name).and_return("paid-needs-input")
        allow(github_client).to receive(:issue).and_return(Struct.new(:body).new(replacement_questions_body))
        allow(github_client).to receive(:update_issue)
        allow(github_client).to receive(:remove_label_from_issue)
        allow(pending_issue).to receive(:update!)

        expect {
          described_class.call(
            project: project,
            issue: pending_issue,
            questions_and_answers: [ { question: "What should Q1 do?", answer: "Answer for Q1" } ]
          )
        }.to raise_error(ClarifyingQuestions::SubmitAnswers::StaleQuestionsError, /changed/)

        expect(github_client).not_to have_received(:update_issue)
        expect(github_client).not_to have_received(:remove_label_from_issue)
        expect(pending_issue).not_to have_received(:update!)
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

    context "with a freeform note" do
      it "appends the note after the Q/A pairs under a stable marker so it is identifiable" do
        questions_and_answers = [ { question: "Q1?", answer: "A1" } ]
        freeform_note = "Cross-cutting context that touches every answer."

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers,
          freeform_note: freeform_note
        )

        expect(github_client).to have_received(:add_comment).with(
          project.full_name,
          issue.github_number,
          a_string_including("<!-- paid:clarifying-answers:freeform-notes -->")
            .and(a_string_including(freeform_note))
        )
      end

      it "does not block submission when the freeform note is blank" do
        questions_and_answers = [ { question: "Q1?", answer: "A1" } ]

        expect {
          described_class.call(
            project: project,
            issue: issue,
            questions_and_answers: questions_and_answers,
            freeform_note: "   "
          )
        }.not_to raise_error
      end

      it "omits the freeform-notes section entirely when the note is blank" do
        questions_and_answers = [ { question: "Q1?", answer: "A1" } ]

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers,
          freeform_note: ""
        )

        expect(github_client).to have_received(:add_comment) do |_repo, _number, body|
          expect(body).not_to include("<!-- paid:clarifying-answers:freeform-notes -->")
        end
      end

      it "omits the freeform-notes section when no note is provided at all" do
        questions_and_answers = [ { question: "Q1?", answer: "A1" } ]

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers
        )

        expect(github_client).to have_received(:add_comment) do |_repo, _number, body|
          expect(body).not_to include("<!-- paid:clarifying-answers:freeform-notes -->")
        end
      end

      it "places the freeform-notes marker on its own line directly after the last A line" do
        questions_and_answers = [ { question: "Q1?", answer: "A1" } ]
        freeform_note = "Operator-wide context."

        described_class.call(
          project: project,
          issue: issue,
          questions_and_answers: questions_and_answers,
          freeform_note: freeform_note
        )

        expect(github_client).to have_received(:add_comment).with(
          anything, anything,
          a_string_matching(/\*\*A1:\*\* A1\n<!-- paid:clarifying-answers:freeform-notes -->/)
        )
      end
    end
  end
end
