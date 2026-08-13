# frozen_string_literal: true

module ClarifyingQuestions
  class Load
    ANSWER_MARKER = "<!-- paid:clarifying-answers -->"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:)
      @project = project
      @issue = issue
    end

    def call
      body_questions = Parse.call(comment_body: issue.body)
      stored_questions = issue.respond_to?(:needs_input_questions) ? Array(issue.needs_input_questions).map { |question| question.to_s.strip }.reject(&:blank?) : []
      current_questions = body_questions.presence || stored_questions

      if current_questions.any?
        return current_questions unless github_available?

        enhancement_comment = latest_enhancement_comment
        current_questions = latest_questions(body_questions: current_questions, enhancement_comment:)
        return reconcile_answered if answered_after_latest_questions?(body_questions: current_questions, enhancement_comment:)

        return current_questions
      end

      return [] unless github_available?

      enhancement_comment = latest_enhancement_comment
      return reconcile_answered if answered_after_latest_questions?(body_questions:, enhancement_comment:)
      return [] unless enhancement_comment

      Parse.call(comment_body: comment_body(enhancement_comment))
    rescue GithubClient::Error
      raise if current_questions.empty?

      current_questions
    end

    private

    attr_reader :project, :issue

    def github_available?
      project.github_credential_present?
    end

    def latest_enhancement_comment
      return unless github_available?

      issue_comments.reverse.find do |comment|
        Parse.call(comment_body: comment_body(comment)).any?
      end
    end

    def answered_after_latest_questions?(body_questions:, enhancement_comment:)
      latest_answer_comment = latest_answer_comment()
      return false unless latest_answer_comment
      return false unless answer_satisfies_latest_questions?(latest_answer_comment, enhancement_comment)

      current_questions = latest_questions(body_questions:, enhancement_comment:)
      parsed_pairs = AnswerPairs.parse(comment_body(latest_answer_comment))

      AnswerPairs.questions_match?(current_questions, parsed_pairs)
    end

    def latest_questions(body_questions:, enhancement_comment:)
      if enhancement_comment.present?
        questions = Parse.call(comment_body: comment_body(enhancement_comment))
        return questions if questions.any?
      end

      body_questions
    end

    def latest_answer_comment
      issue_comments.reverse.find do |comment|
        comment_body(comment).include?(ANSWER_MARKER)
      end
    end

    def answer_satisfies_latest_questions?(answer_comment, enhancement_comment)
      return true unless enhancement_comment

      answer_comment.created_at > enhancement_comment.created_at
    end

    def comment_body(comment)
      comment.body.to_s
    end

    def issue_comments
      @issue_comments ||= project.client.issue_comments(project.full_name, issue.github_number)
        .select { |comment| CommentAdmission.admissible?(project: project, comment: comment) }
    end

    # The clarifying questions have been answered: ingest the answers into the
    # knowledge base and clear the issue's needs-input marker so the stale
    # "Answer Questions" button disappears. Returns [] (no pending questions).
    def reconcile_answered
      ingested = ingest_answers
      ClearNeedsInput.call(project: project, issue: issue) if ingested
      []
    end

    def ingest_answers
      IngestAnswers.call(project: project, issue: issue, issue_comments: issue_comments)
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "clarifying_questions.ingest_answers_failed",
        error: e.message,
        issue_id: issue.respond_to?(:id) ? issue.id : nil
      )
      nil
    end
  end
end
