# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-012
RSpec.describe ClarifyingQuestions::AnswerPairs, :no_db do
  let(:single_choice_question) do
    "Which storage backend should the export use? " \
      "- ( ) SQLite) local file, zero setup " \
      "- ( ) Postgres) already used for app data"
  end
  let(:multi_choice_question) do
    "Which browsers must the export UI support? " \
      "- [ ] Chrome) primary browser " \
      "- [ ] Firefox) required by the support team"
  end

  # Mirrors ClarifyingQuestions::SubmitAnswers#formatted_comment so the
  # round-trip assertion exercises the exact comment shape Paid posts.
  def posted_answer_comment(questions:, answers:)
    parts = [ ClarifyingQuestions::Load::ANSWER_MARKER, "", "## Clarifying question answers", "" ]
    questions.each_with_index do |question, index|
      parts << "**Q#{index + 1}: #{question}**"
      parts << "**A#{index + 1}:** #{answers[index]}"
      parts << ""
    end
    parts.join("\n")
  end

  describe ".parse" do
    it "round-trips a posted answer comment whose answers were composed by the click-to-answer widget" do
      questions = [ single_choice_question, multi_choice_question ]
      answers = [
        "SQLite (local file, zero setup)",
        "Chrome (primary browser)\nOther: Safari for the design team"
      ]

      parsed = described_class.parse(posted_answer_comment(questions:, answers:))

      expect(parsed).to eq(
        [
          { question: questions.first, answer: answers.first },
          { question: questions.second, answer: answers.second }
        ]
      )
      expect(described_class.questions_match?(questions, parsed)).to be(true)
    end

    it "round-trips an appended Details line composed by the widget" do
      answer = "Postgres (already used for app data)\nDetails: needs a connection string setting"
      comment = "**Q1: #{single_choice_question}**\n**A1:** #{answer}"

      expect(described_class.parse(comment).first[:answer]).to eq(answer)
    end

    it "stops parsing each answer at the freeform-notes marker so the notes section is not consumed" do
      question = "What is the expected behavior?"
      answer = "Return a 404 error"
      freeform_note = "Cross-cutting context the operator added outside the question list."
      body = <<~COMMENT
        <!-- paid:clarifying-answers -->

        ## Clarifying question answers

        **Q1: #{question}**
        **A1:** #{answer}
        <!-- paid:clarifying-answers:freeform-notes -->

        #{freeform_note}
      COMMENT

      parsed = described_class.parse(body)

      expect(parsed).to eq([ { question: question, answer: answer } ])
    end

    it "still terminates the last answer when the freeform-notes marker is followed by blank lines and paragraphs" do
      question = "What is the expected behavior?"
      answer = "Return a 404 error"
      body = <<~COMMENT
        **Q1: #{question}**
        **A1:** #{answer}
        <!-- paid:clarifying-answers:freeform-notes -->


        Multi-paragraph

        notes with blank lines.
      COMMENT

      expect(described_class.parse(body).first[:answer]).to eq(answer)
    end

    it "leaves the freeform-notes section unconsumed when there are multiple question pairs" do
      parsed = described_class.parse(posted_answer_comment(questions: [ single_choice_question, multi_choice_question ], answers: [
        "SQLite (local file, zero setup)",
        "Chrome (primary browser)\nOther: Safari for the design team"
      ]) + "\n<!-- paid:clarifying-answers:freeform-notes -->\n\nOperator freeform note.\n")

      expect(parsed.size).to eq(2)
      expect(parsed.map { |pair| pair[:answer] }).to eq([
        "SQLite (local file, zero setup)",
        "Chrome (primary browser)\nOther: Safari for the design team"
      ])
    end
  end
end
