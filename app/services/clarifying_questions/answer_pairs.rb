# frozen_string_literal: true

module ClarifyingQuestions
  module AnswerPairs
    QUESTION_ANSWER_PATTERN = /\*\*Q\d+:\s*(.+?)\*\*\s*\n\*\*A\d+:\*\*\s*(.+?)(?=\n\n\*\*Q|\z)/m.freeze

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
