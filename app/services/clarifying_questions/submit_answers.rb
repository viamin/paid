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
      result = if quiet_mode?
        submit_via_description!
      else
        submit_via_comment!
      end
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

    # Quiet-mode answer channel (#4236): writes the answers into a marked
    # section of the issue/PR description instead of posting a GitHub
    # comment. Body editing is the only permitted channel under
    # QUIET-MODE-002 because the project-scoped GitHub client short-circuits
    # `add_comment` requests when quiet mode is on.
    def submit_via_description!
      body = issue.body.to_s
      questions = questions_and_answers.map { |qa| qa[:question].to_s }
      digest = DescriptionSection.digest_for(questions)
      new_body = DescriptionSection.replace_answers_section(
        body: body,
        answers_block: formatted_answers_block,
        digest: digest
      )
      client = github_client
      result = client.update_issue(project.full_name, issue.github_number, body: new_body)
      update_local_body!(new_body)
      result
    end

    # Mirror the body edit onto the local Issue row so subsequent
    # `ClarifyingQuestions::Load` calls — and any other reader that walks
    # `issue.body` rather than re-fetching from GitHub — see the new
    # answers section without waiting for the next sync cycle.
    def update_local_body!(new_body)
      return unless issue.respond_to?(:update!)
      return if issue.body == new_body

      issue.update!(body: new_body)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "clarifying_questions.submit_answers_body_persist_failed",
        issue_id: issue.respond_to?(:id) ? issue.id : nil,
        error: e.message
      )
    end

    # Comment-channel submission. The exact byte shape of the emitted body
    # is preserved across the quiet-mode switch so existing comments
    # remain byte-identical on parse.
    def submit_via_comment!
      result = github_client.add_comment(project.full_name, issue.github_number, formatted_comment)
      result
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
        parts.pop
      else
        parts[-1] = FREEFORM_NOTES_MARKER
        parts << ""
        parts << trimmed_note
      end

      parts.join("\n")
    end

    # The answers-block payload that lives inside the description's answers
    # section. Reuses the comment-side Q/A wording so the body section
    # parses through `AnswerPairs` without modification.
    def formatted_answers_block
      parts = []
      questions_and_answers.each_with_index do |qa, i|
        parts << "**Q#{i + 1}: #{qa[:question]}**"
        parts << "**A#{i + 1}:** #{qa[:answer]}"
        parts << ""
      end

      trimmed_note = freeform_note.to_s.strip
      if trimmed_note.empty?
        parts.pop
      else
        parts[-1] = FREEFORM_NOTES_MARKER
        parts << ""
        parts << trimmed_note
      end

      parts.join("\n")
    end

    def quiet_mode?
      project.quiet_mode? == true
    end

    def github_client
      project.client
    end
  end
end
