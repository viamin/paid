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

      if body_questions.any?
        return body_questions unless github_available?

        enhancement_comment = latest_enhancement_comment
        return [] if answered_after_latest_questions?(body_questions:, enhancement_comment:)

        return body_questions
      end

      return [] unless github_available?

      enhancement_comment = latest_enhancement_comment
      return [] if answered_after_latest_questions?(body_questions:, enhancement_comment:)
      return [] unless enhancement_comment

      Parse.call(comment_body: comment_body(enhancement_comment))
    rescue GithubClient::Error
      raise if body_questions.empty?

      body_questions
    end

    private

    attr_reader :project, :issue

    def github_available?
      project.github_token.present?
    end

    def latest_enhancement_comment
      return unless github_available?

      issue_comments.reverse.find do |comment|
        comment_body(comment).include?(Parse::ENHANCEMENT_MARKER) &&
          comment_body(comment).include?("## Clarifying questions")
      end
    end

    def answered_after_latest_questions?(body_questions:, enhancement_comment:)
      latest_answer_comment = latest_answer_comment()
      return false unless latest_answer_comment

      latest_answer_timestamp = comment_timestamp(latest_answer_comment)
      latest_question_timestamp = latest_question_timestamp(
        body_questions: body_questions,
        enhancement_comment: enhancement_comment
      )
      return false unless latest_question_timestamp

      latest_answer_timestamp > latest_question_timestamp
    end

    def latest_question_timestamp(body_questions:, enhancement_comment:)
      timestamps = []
      timestamps << issue_timestamp if body_questions.any?
      timestamps << comment_timestamp(enhancement_comment) if enhancement_comment.present?

      timestamps.compact.max
    end

    def latest_answer_comment
      issue_comments.reverse.find do |comment|
        comment_body(comment).include?(ANSWER_MARKER)
      end
    end

    def comment_body(comment)
      comment.body.to_s
    end

    def comment_timestamp(comment)
      comment.created_at&.to_time || Time.at(0)
    end

    def issue_timestamp
      issue.github_updated_at&.to_time || issue.updated_at&.to_time || Time.at(0)
    end

    def issue_comments
      @issue_comments ||= project.github_token.client.issue_comments(project.full_name, issue.github_number)
    end
  end
end
