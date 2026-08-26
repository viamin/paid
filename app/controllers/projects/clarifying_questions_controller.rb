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
        redirect_to empty_questions_redirect_path, alert: "No clarifying questions found for #{issue_kind_label} ##{@issue.github_number}."
      end
    rescue GithubClient::Error => e
      redirect_to empty_questions_redirect_path, alert: "Failed to load clarifying questions: #{e.message}"
    end

    def create
      next_issue = next_queue_issue
      questions_and_answers = build_questions_and_answers(questions: current_questions)

      ClarifyingQuestions::SubmitAnswers.call(
        project: @project,
        issue: @issue,
        questions_and_answers: questions_and_answers
      )

      if queue_mode? && next_issue
        redirect_to project_issue_clarifying_questions_path(
          next_issue.project,
          next_issue,
          queue_redirect_params
        ), notice: "Answers posted to GitHub #{issue_kind_label} ##{@issue.github_number}. Next questionnaire ready."
      elsif queue_mode?
        redirect_to queue_return_to, notice: "Answers posted to GitHub #{issue_kind_label} ##{@issue.github_number}. You've completed the needs-input queue."
      else
        redirect_to project_path(@project), notice: "Answers posted to GitHub #{issue_kind_label} ##{@issue.github_number}. The agent will pick them up on the next run."
      end
    rescue ArgumentError => e
      redirect_to project_issue_clarifying_questions_path(@project, @issue, queue_redirect_params), alert: e.message
    rescue GithubClient::Error => e
      redirect_to project_issue_clarifying_questions_path(@project, @issue, queue_redirect_params), alert: "Failed to post answers: #{e.message}"
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_issue
      @issue = @project.issues.find(params[:issue_id])
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

    def queue_mode?
      %w[dashboard_needs_input dashboard_inbox].include?(queue_param)
    end

    def queue_param
      params[:queue].to_s
    end

    # Resolves the project whose queue the user was browsing from
    # +queue_project_id+. It must resolve even when that project's
    # question-backed queue is momentarily empty (e.g. the last stale
    # needs-input row was just cleared) so the fallback redirect keeps its
    # project scope. Accessibility is already enforced by +policy_scope+.
    def queue_project
      return unless queue_mode? && params[:queue_project_id].present?

      @queue_project ||= policy_scope(Project).find_by(id: params[:queue_project_id])
    end

    def queue_return_to
      @queue_return_to ||= begin
        requested = normalized_return_to(params[:return_to])
        if requested.present? && safe_queue_return_to?(requested)
          requested
        elsif queue_param == "dashboard_inbox"
          dashboard_inbox_path(
            project_id: queue_project&.id,
            kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
          )
        else
          dashboard_needs_input_path(project_id: queue_project&.id)
        end
      end
    end

    def queue_redirect_params
      return {} unless queue_mode?

      {
        queue: queue_param,
        queue_project_id: queue_project&.id,
        return_to: queue_return_to
      }
    end

    def next_queue_issue
      return unless queue_mode?
      return unless valid_queue_scope?

      current_index = queue_scope_issues(project: queue_project).index { |issue| issue.id == @issue.id }
      return if current_index.nil?

      queue_scope_issues(project: queue_project)[(current_index + 1)..]&.first
    end

    def safe_queue_return_to?(path)
      return false if path.blank?

      path.start_with?(dashboard_needs_input_path) || path.start_with?(dashboard_inbox_path)
    end

    def empty_questions_redirect_path
      queue_mode? ? queue_return_to : project_path(@project)
    end

    def issue_kind_label
      helpers.issue_kind_label(@issue, style: :short_lower)
    end

    def queue_scope_issues(project:)
      @queue_scope_issues ||= {}
      cache_key = [ queue_param, project&.id ]
      @queue_scope_issues.fetch(cache_key) do
        @queue_scope_issues[cache_key] = queue_scope_entries(project: project).map(&:issue)
      end
    end

    # @spec OPERATOR-INBOX-007
    def queue_scope_entries(project:)
      if queue_param == "dashboard_inbox"
        Inbox::Queue.call(
          user: current_user,
          project: project,
          kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND
        )
      else
        Dashboard::NeedsInputQueue.call(user: current_user, project: project)
      end
    end

    def valid_queue_scope?
      return false if params[:queue_project_id].present? && queue_project.nil?

      queue_scope_issues(project: queue_project).any? { |issue| issue.id == @issue.id }
    end
  end
end
