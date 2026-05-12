# frozen_string_literal: true

module ClarifyingQuestions
  class SubmitAnswers
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, questions_and_answers:)
      @project = project
      @issue = issue
      @questions_and_answers = questions_and_answers
    end

    def call
      validate_answers!
      client = project.github_token.client
      client.add_comment(project.full_name, issue.github_number, formatted_comment)
    end

    private

    attr_reader :project, :issue, :questions_and_answers

    def validate_answers!
      raise ArgumentError, "No clarifying questions found for this issue." if questions_and_answers.empty?

      missing_questions = questions_and_answers.select { |qa| qa[:question].blank? }
      if missing_questions.any?
        raise ArgumentError, "Clarifying question text is missing for #{missing_questions.size} item(s)."
      end

      missing = questions_and_answers.select { |qa| qa[:answer].blank? }
      return if missing.empty?

      raise ArgumentError, "All questions must be answered. #{missing.size} question(s) are blank."
    end

    def formatted_comment
      parts = [ "<!-- paid:clarifying-answers -->", "", "## Clarifying question answers", "" ]
      questions_and_answers.each_with_index do |qa, i|
        parts << "**Q#{i + 1}: #{qa[:question]}**"
        parts << qa[:answer]
        parts << ""
      end
      parts.join("\n")
    end
  end
end
