# frozen_string_literal: true

module ClarifyingQuestions
  class Load
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:)
      @project = project
      @issue = issue
    end

    def call
      questions = Parse.call(comment_body: issue.body)
      return questions if questions.any?
      return [] unless project.github_token

      enhancement_comment = issue_comments.reverse.find do |comment|
        comment.body.to_s.include?(Parse::ENHANCEMENT_MARKER) &&
          comment.body.to_s.include?("## Clarifying questions")
      end
      return [] unless enhancement_comment

      Parse.call(comment_body: enhancement_comment.body)
    end

    private

    attr_reader :project, :issue

    def issue_comments
      project.github_token.client.issue_comments(project.full_name, issue.github_number)
    end
  end
end
