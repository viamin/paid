# frozen_string_literal: true

module ClarifyingQuestions
  class ExtractAnswerPairs
    ANSWER_PATTERN = /\*\*A\d+:\*\*\s*(.+?)(?=\n\n\*\*|\z)/m.freeze

    Result = Struct.new(:qa_pairs, :answer_comment, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue_comments:, issue: nil)
      @project = project
      @issue_comments = Array(issue_comments)
      @issue = issue
    end

    def call
      enhancement_comment = find_enhancement_comment
      return empty_result unless enhancement_comment

      answer_comment = find_answer_comment
      return empty_result unless answer_comment
      return empty_result unless answer_newer_than_latest_questions?(answer_comment, enhancement_comment)

      questions = Parse.call(comment_body: enhancement_comment.body.to_s)
      answers = parse_answers(answer_comment.body.to_s)
      qa_pairs = pair_qa(questions, answers)

      Result.new(qa_pairs: qa_pairs, answer_comment: answer_comment)
    end

    private

    attr_reader :project, :issue_comments, :issue

    def empty_result
      Result.new(qa_pairs: [], answer_comment: nil)
    end

    def admitted_comments
      @admitted_comments ||= issue_comments.select do |comment|
        CommentAdmission.admissible?(project: project, comment: comment)
      end
    end

    def find_enhancement_comment
      admitted_comments.reverse.find do |comment|
        body = comment.body.to_s
        body.include?(Parse::ENHANCEMENT_MARKER) &&
          body.include?("## Clarifying questions")
      end
    end

    def find_answer_comment
      admitted_comments.reverse.find do |comment|
        comment.body.to_s.include?(Load::ANSWER_MARKER)
      end
    end

    def answer_newer_than_latest_questions?(answer_comment, enhancement_comment)
      answer_time = comment_timestamp(answer_comment)
      latest_question_time = latest_question_timestamp(enhancement_comment)

      answer_time > latest_question_time
    end

    def latest_question_timestamp(enhancement_comment)
      [
        comment_timestamp(enhancement_comment),
        issue_timestamp
      ].compact.max || Time.at(0)
    end

    def comment_timestamp(comment)
      comment.created_at&.to_time || Time.at(0)
    end

    def issue_timestamp
      return unless issue

      issue.github_updated_at&.to_time || issue.updated_at&.to_time
    end

    def parse_answers(body)
      body.scan(ANSWER_PATTERN).map { |match| match[0].strip }
    end

    def pair_qa(questions, answers)
      questions.each_with_index.filter_map do |question, index|
        next if answers[index].blank?

        { question: question, answer: answers[index] }
      end
    end
  end
end
