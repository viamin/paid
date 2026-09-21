# frozen_string_literal: true

module ClarifyingQuestions
  module AnswerPairs
    # Local alias to the freeform-notes marker so the regex below matches the
    # exact HTML comment that SubmitAnswers emits, instead of any `<!--` opener.
    # A broader pattern (e.g. `\n<!--`) would silently truncate operator answers
    # that happen to contain pasted code, documentation, or any other multiline
    # content starting with an HTML comment at the beginning of a line.
    FREEFORM_NOTES_MARKER = SubmitAnswers::FREEFORM_NOTES_MARKER

    # Each answer terminates at the next paired-question start (`\n\n**Q`),
    # the exact `FREEFORM_NOTES_MARKER` that SubmitAnswers emits after the last
    # Q/A pair, or end of string — so the trailing
    # `<!-- paid:clarifying-answers:freeform-notes -->` block is not folded into
    # the previous answer's body, and arbitrary `<!--` sequences inside an
    # answer body are left untouched.
    QUESTION_ANSWER_PATTERN = /\*\*Q\d+:\s*(.+?)\*\*\s*\n\*\*A\d+:\*\*\s*(.+?)(?=\n\n\*\*Q|\n#{Regexp.escape(FREEFORM_NOTES_MARKER)}|\z)/m.freeze

    module_function

    def parse(body)
      body.to_s.scan(QUESTION_ANSWER_PATTERN).map do |question, answer|
        {
          question: normalize_question(question),
          answer: answer.to_s.strip
        }
      end
    end

    def questions_match?(questions, parsed_pairs)
      normalize_questions(questions) == parsed_pairs.map { |pair| pair[:question] }
    end

    def normalize_questions(questions)
      Array(questions).map { |question| normalize_question(question) }
    end

    def normalize_question(question)
      question.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
