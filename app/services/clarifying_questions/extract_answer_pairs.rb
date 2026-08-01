# frozen_string_literal: true

module ClarifyingQuestions
  class ExtractAnswerPairs
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

      answer_comment = find_answer_comment(enhancement_comment)
      return empty_result unless answer_comment

      questions = Parse.call(comment_body: enhancement_comment.body.to_s)
      parsed_pairs = AnswerPairs.parse(answer_comment.body.to_s)
      return empty_result unless AnswerPairs.questions_match?(questions, parsed_pairs)

      qa_pairs = pair_qa(questions, parsed_pairs)

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

    def find_answer_comment(enhancement_comment)
      admitted_comments.reverse.find do |comment|
        comment.body.to_s.include?(Load::ANSWER_MARKER) &&
          answer_satisfies_latest_questions?(answer_comment: comment, enhancement_comment: enhancement_comment)
      end
    end

    def answer_satisfies_latest_questions?(answer_comment:, enhancement_comment:)
      answer_comment.created_at > enhancement_comment.created_at
    end

    def pair_qa(questions, parsed_pairs)
      questions.each_with_index.filter_map do |question, index|
        answer = parsed_pairs[index]&.fetch(:answer, nil)
        next if answer.blank?

        { question: question, answer: answer }
      end
    end
  end
end
