# frozen_string_literal: true

module Projects
  class ClarifyingQuestionsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project
    before_action :set_issue
    before_action :authorize_project_show, only: [ :show ]
    before_action :authorize_project_update, only: [ :create ]

    def show
      @questions = ClarifyingQuestions::Load.call(project: @project, issue: @issue)

      if @questions.empty?
        redirect_to project_path(@project), alert: "No clarifying questions found for issue ##{@issue.github_number}."
      end
    rescue GithubClient::Error => e
      redirect_to project_path(@project), alert: "Failed to load clarifying questions: #{e.message}"
    end

    def create
      questions_and_answers = build_questions_and_answers(questions: current_questions)

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

    def current_questions
      @current_questions ||= ClarifyingQuestions::Load.call(project: @project, issue: @issue)
    end

    def build_questions_and_answers(questions:)
      answers = Array(params[:answers])
      submitted_questions = Array(params[:questions]).map { |question| question.to_s.strip }

      raise ArgumentError, "No clarifying questions found for this issue." if questions.empty?
      unless submitted_questions == questions
        raise ArgumentError, "Clarifying questions changed. Please reload and try again."
      end

      questions.each_with_index.map do |question, i|
        { question: question, answer: answers[i].to_s.strip }
      end
    end
  end
end
