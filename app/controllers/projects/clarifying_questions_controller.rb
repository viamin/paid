# frozen_string_literal: true

module Projects
  class ClarifyingQuestionsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project
    before_action :set_issue
    before_action :authorize_project_show, only: [ :show ]
    before_action :authorize_project_update, only: [ :create ]

    def show
      @questions = fetch_questions

      if @questions.empty?
        redirect_to project_path(@project), alert: "No clarifying questions found for issue ##{@issue.github_number}."
      end
    end

    def create
      questions_and_answers = build_questions_and_answers

      ClarifyingQuestions::SubmitAnswers.call(
        project: @project,
        issue: @issue,
        questions_and_answers: questions_and_answers
      )

      redirect_to project_path(@project), notice: "Answers posted to GitHub issue ##{@issue.github_number}. The agent will pick them up on the next run."
    rescue ArgumentError => e
      redirect_to project_issue_clarifying_questions_path(@project, @issue), alert: e.message
    rescue GithubClient::Error => e
      redirect_to project_issue_clarifying_questions_path(@project, @issue), alert: "Failed to post answers: #{e.message}"
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_issue
      @issue = @project.issues.issues_only.find(params[:issue_id])
    end

    def authorize_project_show
      authorize @project, :show?
    end

    def authorize_project_update
      authorize @project, :update?
    end

    def fetch_questions
      questions = ClarifyingQuestions::Parse.call(comment_body: @issue.body)
      return questions if questions.any?

      client = @project.github_token.client
      comments = client.issue_comments(@project.full_name, @issue.github_number)
      enhancement_comment = comments.reverse.find do |comment|
        comment.body.to_s.include?(ClarifyingQuestions::Parse::ENHANCEMENT_MARKER) &&
          comment.body.to_s.include?("## Clarifying questions")
      end
      return [] unless enhancement_comment

      ClarifyingQuestions::Parse.call(comment_body: enhancement_comment.body)
    end

    def build_questions_and_answers
      questions = params[:questions] || []
      answers = params[:answers] || []

      questions.each_with_index.map do |question, i|
        { question: question, answer: answers[i].to_s.strip }
      end
    end
  end
end
