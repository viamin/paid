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

    # @spec QUIET-MODE-011
    def call
      body_questions = Parse.call(comment_body: issue.body)
      stored_questions = issue.respond_to?(:needs_input_questions) ? Array(issue.needs_input_questions).map { |question| question.to_s.strip }.reject(&:blank?) : []
      current_questions = body_questions.presence || stored_questions

      if current_questions.any?
        return current_questions unless github_available?

        return reconcile_answered if quiet_mode? && answered_via_body?(current_questions)
        return reconcile_answered if answered_after_latest_questions?(body_questions: current_questions)

        return latest_comment_questions || current_questions
      end

      return [] unless github_available?

      return reconcile_answered if quiet_mode? && answered_via_body?([])
      enhancement_comment = latest_enhancement_comment
      return reconcile_answered if answered_after_latest_questions?(body_questions:)

      return [] unless enhancement_comment

      Parse.call(comment_body: comment_body(enhancement_comment))
    rescue GithubClient::Error
      raise if current_questions.empty?

      current_questions
    end

    # Returns the markdown for the agent-authored context sections that
    # surrounded the clarifying questions in the latest enhancement comment
    # (the "Current Context" section plus the prose preceding the numbered
    # list). Reuses the cached issue_comments list so we never make a second
    # GitHub API call from the inbox just to render context. Returns nil when
    # GitHub credentials are missing, when the questions came from locally
    # persisted needs_input_questions rather than a fetched comment, when a
    # transient GitHub error blocks the fetch, or when the comment body has
    # no recoverable context — callers use a single nil-check to decide
    # whether to show the panel.
    #
    # In quiet mode (#4236), the questions live in the description's marked
    # section rather than in a GitHub comment, so the context block falls
    # back to the section's preamble when the description carries the
    # questions.
    def context_markdown
      section_context = description_section_context_markdown
      return section_context unless section_context.nil?

      return nil unless github_available?

      enhancement_comment = latest_enhancement_comment
      return nil unless enhancement_comment

      Context.call(comment_body: comment_body(enhancement_comment))
    rescue GithubClient::Error
      nil
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

    # Reads the description's clarifying-questions section (the body-channel
    # equivalent of `latest_enhancement_comment`) and reports whether the
    # questions were answered in the same body. Freshness between the
    # questions and answers sections is the question-set digest embedded in
    # both sections, not `comment.created_at` (#4236).
    def answered_via_body?(body_questions)
      parsed_answers = DescriptionSection.parse_answers(issue.body)
      return false unless parsed_answers

      current_questions = body_questions.presence || DescriptionSection.parse_questions(issue.body).questions
      current_questions = current_questions.presence || Array(issue.respond_to?(:needs_input_questions) ? issue.needs_input_questions : [])
      return false if current_questions.empty?

      parsed_pairs = AnswerPairs.parse(parsed_answers[:inner].to_s)
      return false unless AnswerPairs.questions_match?(current_questions, parsed_pairs)
      return false if parsed_pairs.any? { |pair| pair[:answer].blank? }

      current_digest = DescriptionSection.digest_for(current_questions)
      parsed_answers[:digest].blank? || parsed_answers[:digest] == current_digest
    end

    # Render the description-section context when the questions live in the
    # body. Quiet-mode body sections carry a digest line that has to be
    # stripped before the surrounding prose is rendered, and they may not
    # carry a "Current Context" block — the section's preamble (everything
    # before the numbered list) is the fallback the inbox needs.
    def description_section_context_markdown
      parsed = DescriptionSection.parse_questions(issue.body)
      return nil unless parsed.any?

      inner = extract_questions_inner(parsed.raw_body)
      return nil if inner.blank?

      Context.call(comment_body: inner)
    end

    def extract_questions_inner(section_block)
      match = section_block.to_s.match(DescriptionSection::QUESTIONS_SECTION_PATTERN)
      return nil unless match

      match[1].to_s
    end

    def answered_after_latest_questions?(body_questions:)
      latest_answer_comment = latest_answer_comment()
      return false unless latest_answer_comment
      return false unless answer_satisfies_latest_questions?(latest_answer_comment)

      enhancement_comment = latest_enhancement_comment
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

    def latest_comment_questions
      enhancement_comment = latest_enhancement_comment
      return unless enhancement_comment

      Parse.call(comment_body: comment_body(enhancement_comment)).presence
    end

    def answer_satisfies_latest_questions?(answer_comment)
      enhancement_comment = latest_enhancement_comment
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
      if quiet_mode? && body_answers?
        IngestAnswers.call(project: project, issue: issue, issue_body: issue.body)
      else
        IngestAnswers.call(project: project, issue: issue, issue_comments: issue_comments)
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn(
        message: "clarifying_questions.ingest_answers_failed",
        error: e.message,
        issue_id: issue.respond_to?(:id) ? issue.id : nil
      )
      nil
    end

    def body_answers?
      DescriptionSection.parse_answers(issue.body).present?
    end

    def quiet_mode?
      project.quiet_mode? == true
    end
  end
end
