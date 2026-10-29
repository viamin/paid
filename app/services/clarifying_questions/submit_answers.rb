# frozen_string_literal: true

module ClarifyingQuestions
  class SubmitAnswers
    ANSWER_MARKER = Load::ANSWER_MARKER
    StaleQuestionsError = Class.new(ArgumentError)
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
      ensure_manual_review_accepts_answers!
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

    # A hidden or stale form must not turn retained questions into authority to
    # clear a newer hold. This guard runs before posting to GitHub so every
    # shared submission entry point follows the Inbox recovery classification.
    # @spec OPERATOR-INBOX-002L
    def ensure_manual_review_accepts_answers!
      return unless issue.respond_to?(:paid_state) && issue.paid_state == "manual_review"

      recovery = Inbox::ManualReviewRecovery.call(issue: issue)
      return if recovery.enhancement?

      raise ArgumentError,
        "This manual-review hold requires #{recovery.kind.to_s.humanize.downcase} recovery before clarifying-question answers can be submitted."
    end

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
      questions = questions_and_answers.map { |qa| qa[:question].to_s }
      digest = DescriptionSection.digest_for(questions)
      result, new_body = DescriptionSection.update_issue_body(
        client: github_client, repo: project.full_name, number: issue.github_number
      ) do |body|
        ensure_questions_are_current!(body, digest)
        DescriptionSection.replace_answers_section(
          body: body,
          answers_block: formatted_answers_block,
          digest: digest
        )
      end
      update_local_body!(new_body)
      result
    end

    # The form's questions came from an earlier load. The remote description
    # can change between that load and this write, so answers must only be
    # attached to the same question set. Raising here also prevents the
    # caller from clearing the newer set's needs-input state.
    # @spec QUIET-MODE-010 @spec QUIET-MODE-011
    def ensure_questions_are_current!(body, digest)
      remote_questions = DescriptionSection.parse_questions(body).questions
      return if remote_questions.any? && DescriptionSection.digest_for(remote_questions) == digest

      raise StaleQuestionsError, "Clarifying questions changed. Please reload and try again."
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
    #
    # GitHub's comment endpoint has no request idempotency key. Before a
    # retry, identify an already-posted matching answer block so a timeout
    # after GitHub accepted the first request cannot duplicate human intent.
    # Any lookup failure intentionally propagates to the caller: guessing and
    # posting again would make synchronization non-idempotent.
    # @spec QUESTION-EXPLORATION-002
    def submit_via_comment!
      matching_answer_comment || github_client.add_comment(project.full_name, issue.github_number, formatted_comment)
    end

    def matching_answer_comment
      github_client.issue_comments(project.full_name, issue.github_number).reverse.find do |comment|
        comment.body.to_s.include?(ANSWER_MARKER) && answers_match?(comment.body)
      end
    end

    def answers_match?(body)
      expected = questions_and_answers.map { |qa| { question: AnswerPairs.normalize_question(qa[:question]), answer: qa[:answer].to_s.strip } }
      AnswerPairs.parse(body) == expected
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
