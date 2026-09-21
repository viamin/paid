# frozen_string_literal: true

module ClarifyingQuestions
  class SubmitAnswers
    ANSWER_MARKER = Load::ANSWER_MARKER
    # Stable HTML marker that delimits the operator's freeform note (not tied
    # to any individual question). Also serves as the boundary that stops
    # ClarifyingQuestions::AnswerPairs from folding the notes block into the
    # last Q/A answer — see QUESTION_ANSWER_PATTERN.
    FREEFORM_NOTES_MARKER = "<!-- paid:clarifying-answers:freeform-notes -->"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, questions_and_answers:, freeform_note: nil)
      @project = project
      @issue = issue
      @questions_and_answers = questions_and_answers
      @freeform_note = freeform_note.to_s
    end

    def call
      validate_answers!
      result = github_client.add_comment(project.full_name, issue.github_number, formatted_comment)
      ClearNeedsInput.call(project: project, issue: issue)
      result
    end

    private

    attr_reader :project, :issue, :questions_and_answers, :freeform_note

    def validate_answers!
      raise ArgumentError, "No clarifying questions found for this issue." if questions_and_answers.empty?
      raise ArgumentError, "GitHub access is not configured for this project." unless github_client

      missing_questions = questions_and_answers.select { |qa| qa[:question].blank? }
      if missing_questions.any?
        raise ArgumentError, "Clarifying question text is missing for #{missing_questions.size} item(s)."
      end

      missing = questions_and_answers.select { |qa| qa[:answer].blank? }
      return if missing.empty?

      raise ArgumentError, "All questions must be answered. #{missing.size} question(s) are blank."
    end

    def formatted_comment
      parts = [ ANSWER_MARKER, "", "## Clarifying question answers", "" ]
      questions_and_answers.each_with_index do |qa, i|
        parts << "**Q#{i + 1}: #{qa[:question]}**"
        parts << "**A#{i + 1}:** #{qa[:answer]}"
        parts << ""
      end

      trimmed_note = freeform_note.to_s.strip
      if trimmed_note.empty?
        # Drop the trailing blank separator the loop appended after the
        # final Q/A pair so existing comments keep their byte-identical
        # shape — the new marker-and-notes block adds its own blanks below.
        parts.pop
      else
        # Replace the last blank with the marker on its own line so
        # AnswerPairs's regex terminates the answer at `\n<!--` instead of
        # pulling the whole notes block into the answer body.
        parts[-1] = FREEFORM_NOTES_MARKER
        parts << ""
        parts << trimmed_note
      end

      parts.join("\n")
    end

    def github_client
      project.client
    end
  end
end
