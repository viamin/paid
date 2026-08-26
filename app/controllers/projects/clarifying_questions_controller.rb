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
        redirect_to empty_questions_redirect_path, alert: "No clarifying questions found for issue ##{@issue.github_number}."
      end
    rescue GithubClient::Error => e
      redirect_to empty_questions_redirect_path, alert: "Failed to load clarifying questions: #{e.message}"
    end

    def create
      next_issue = next_queue_issue if queue_mode?
      questions_and_answers = build_questions_and_answers(questions: current_questions)

      ClarifyingQuestions::SubmitAnswers.call(
        project: @project,
        issue: @issue,
        questions_and_answers: questions_and_answers
      )

      if inbox_mode?
        inbox_redirect_target(next_entry: inbox_next_entry)
      elsif queue_mode?
        redirect_after_queue(next_issue)
      else
        redirect_to project_path(@project), notice: "Answers posted to GitHub issue ##{@issue.github_number}. The agent will pick them up on the next run."
      end
    rescue ArgumentError => e
      redirect_to failure_redirect_path, alert: e.message
    rescue GithubClient::Error => e
      redirect_to failure_redirect_path, alert: "Failed to post answers: #{e.message}"
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

    def queue_mode?
      %w[dashboard_needs_input dashboard_inbox].include?(queue_param)
    end

    # The inbox detail pane is a one-page form that submits with `inbox=1`.
    # On success the controller redirects to the next inbox entry so the
    # frame auto-loads; on error it bounces back into the same frame so the
    # user can correct the answer without losing their work.
    def inbox_mode?
      params[:inbox].to_s == "1"
    end

    # Picks the redirect target for the legacy wizard-style queue flow.
    # When a follow-up issue exists, chain the user to it; when the queue
    # is drained, fall back to the validated return target.
    def redirect_after_queue(next_issue)
      if next_issue
        redirect_to project_issue_clarifying_questions_path(
          next_issue.project,
          next_issue,
          queue_redirect_params
        ), notice: "Answers posted to GitHub issue ##{@issue.github_number}. Next questionnaire ready."
      else
        redirect_to queue_return_to, notice: "Answers posted to GitHub issue ##{@issue.github_number}. You've completed the needs-input queue."
      end
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

      Dashboard::NeedsInputQueue.next_issue(
        user: current_user,
        project: queue_project,
        after_issue: @issue
      )
    end

    def safe_queue_return_to?(path)
      return false if path.blank?

      path.start_with?(dashboard_needs_input_path) || path.start_with?(dashboard_inbox_path)
    end

    def normalized_return_to(candidate)
      return if candidate.blank?

      candidate = candidate.to_s
      return unless candidate.start_with?("/") && !candidate.start_with?("//")

      url_from(candidate)
    rescue URI::InvalidURIError
      nil
    end

    def empty_questions_redirect_path
      queue_mode? ? queue_return_to : project_path(@project)
    end

    def queue_scope_issues(project:)
      @queue_scope_issues ||= {}
      @queue_scope_issues.fetch(project&.id) do
        @queue_scope_issues[project&.id] = Dashboard::NeedsInputQueue.call(user: current_user, project: project).map(&:issue)
      end
    end

    def valid_queue_scope?
      return false if params[:queue_project_id].present? && queue_project.nil?

      queue_scope_issues(project: queue_project).any? { |issue| issue.id == @issue.id }
    end

    # Builds the success-redirect path the inbox form lands on. When a next
    # entry is available, auto-advance points the detail frame at it; when
    # the queue is drained, falls back to the bare inbox index so the
    # Turbo Frame reloads the empty state.
    def inbox_redirect_target(next_entry:)
      target_params = {
        project_id: @project.id,
        kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
        selected: next_entry ? "#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:#{next_entry.record.id}" : nil
      }.compact

      notice_suffix = next_entry ? "Loading next questionnaire." : "You've completed the clarifying-questions queue."
      redirect_to dashboard_inbox_path(**target_params),
        notice: "Answers posted to GitHub issue ##{@issue.github_number}. #{notice_suffix}"
    end

    # Resolves the next inbox entry from the same scope the user was browsing
    # (project filter + clarifying-questions kind). Returns nil when the
    # queue is drained so the redirect collapses to the bare inbox index.
    def inbox_next_entry
      project_scope = inbox_scoped_project
      Inbox::Queue
        .call(user: current_user, project: project_scope, kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
        .reject { |entry| entry.record.id == @issue.id && entry.kind == Inbox::Queue::CLARIFYING_QUESTIONS_KIND }
        .first
    end

    def inbox_scoped_project
      return @inbox_scoped_project if defined?(@inbox_scoped_project)

      @inbox_scoped_project = if params[:inbox_project_id].present?
        policy_scope(Project).find_by(id: params[:inbox_project_id])
      end
    end

    # The inbox form posts inside a Turbo Frame; on failure the redirect must
    # land inside the same frame so the user keeps their answers and the
    # pane scrolls back into view.
    def failure_redirect_path
      if inbox_mode?
        dashboard_inbox_path(
          project_id: @project.id,
          kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
          selected: "#{Inbox::Queue::CLARIFYING_QUESTIONS_KIND}:#{@issue.id}"
        )
      elsif queue_mode?
        project_issue_clarifying_questions_path(@project, @issue, queue_redirect_params)
      else
        project_issue_clarifying_questions_path(@project, @issue)
      end
    end
  end
end
