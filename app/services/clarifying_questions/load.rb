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
      return body_questions if body_questions.any? && !github_available?

      enhancement_comment = latest_enhancement_comment
      return [] if answered_after_enhancement?(enhancement_comment)
      return body_questions if body_questions.any?
      return [] unless enhancement_comment

      Parse.call(comment_body: comment_body(enhancement_comment))
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

    def answered_after_enhancement?(enhancement_comment)
      return false unless enhancement_comment

      latest_answer_comment = issue_comments.reverse.find do |comment|
        comment_body(comment).include?(ANSWER_MARKER)
      end
      return false unless latest_answer_comment

      comment_timestamp(latest_answer_comment) > comment_timestamp(enhancement_comment)
    end

    def comment_body(comment)
      comment.body.to_s
    end

    def comment_timestamp(comment)
      comment.created_at&.to_time || Time.at(0)
    end

    def issue_comments
      project.github_token.client.issue_comments(project.full_name, issue.github_number)
    end
  end
end
