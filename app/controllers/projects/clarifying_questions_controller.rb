# frozen_string_literal: true

module Projects
  class ClarifyingQuestionsController < ApplicationController
    # Per-answer byte cap for the inbox form's pending-answers flash payload.
    # Each answer is trimmed to this length before storage.
    MAX_PENDING_ANSWER_BYTES = 2_000
    # Total byte cap for the entire pending-answers payload (all answers for
    # one issue), measured on the JSON-serialized form (matching how the
    # session cookie actually encodes flash data: \uXXXX-escaped non-ASCII,
    # then encrypted/MAC'd and base64'd on top, which roughly doubles the
    # payload before session_id/warden key/alert are even added). CookieStore
    # sessions have a ~4KB ceiling; we leave generous headroom so we never
    # overflow and silently drop the prefill rather than corrupt the cookie.
    MAX_PENDING_ANSWERS_BYTES = 1_500

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
        redirect_to project_path(@project), notice: "Answers posted to GitHub #{issue_kind_label} ##{@issue.github_number}. The agent will pick them up on the next run."
      end
    rescue ArgumentError => e
      remember_pending_inbox_answers if pending_answers_apply_to_current_questions?
      redirect_to failure_redirect_path, alert: e.message
    rescue GithubClient::Error => e
      remember_pending_inbox_answers
      redirect_to failure_redirect_path, alert: "Failed to post answers: #{e.message}"
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

    # True when the operator's submitted questions still match the issue's
    # current questions. Used to gate the inbox prefill so we don't line up
    # saved answers with a different question set after a question-mismatch
    # failure: rehydrating by index would show old answers under the new
    # questions and let the operator repost them against prompts that no
    # longer match.
    def pending_answers_apply_to_current_questions?
      Array(params[:questions]).map { |question| question.to_s.strip } == current_questions
    end

    def queue_mode?
      %w[dashboard_needs_input dashboard_inbox].include?(queue_param)
    end

    # @spec OPERATOR-INBOX-008
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
        ), notice: "Answers posted to GitHub #{issue_kind_label} ##{@issue.github_number}. Next questionnaire ready."
      else
        redirect_to queue_return_to, notice: "Answers posted to GitHub #{issue_kind_label} ##{@issue.github_number}. You've completed the needs-input queue."
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

      current_index = queue_scope_issues(project: queue_project).index { |issue| issue.id == @issue.id }
      return if current_index.nil?

      queue_scope_issues(project: queue_project)[(current_index + 1)..]&.first
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

    # @spec OPERATOR-INBOX-008
    # Builds the success-redirect path the inbox form lands on. When a next
    # entry is available, auto-advance points the detail frame at it; when
    # the queue is drained, falls back to the bare inbox index so the
    # Turbo Frame reloads the empty state.
    def inbox_redirect_target(next_entry:)
      notice_suffix = next_entry ? "Loading next entry." : inbox_drained_notice
      redirect_to dashboard_inbox_path(**inbox_redirect_params(selected_entry: next_entry, detail_view: next_entry.present?)),
        notice: "Answers posted to GitHub issue ##{@issue.github_number}. #{notice_suffix}"
    end

    # Resolves the next inbox entry from the same scope the user was browsing
    # (project filter + inbox-kind filter, including nil for the mixed "All"
    # tab). Returns nil when the queue is drained so the redirect collapses
    # to the bare inbox index.
    def inbox_next_entry
      project_scope = inbox_scoped_project
      Inbox::Queue
        .call(user: current_user, project: project_scope, kind: inbox_kind)
        .reject { |entry| entry.record.id == @issue.id && entry.kind == Inbox::Queue::CLARIFYING_QUESTIONS_KIND }
        .first
    end

    def inbox_scoped_project
      return @inbox_scoped_project if defined?(@inbox_scoped_project)

      @inbox_scoped_project = if params[:inbox_project_id].present?
        policy_scope(Project).find_by(id: params[:inbox_project_id])
      end
    end

    # The inbox-kind filter the operator was viewing when they submitted.
    # Submitted by the inbox form via a hidden field; nil signals the
    # mixed "All" tab. When the form predates that field (or the value is
    # unrecognised) we fall back to the clarifying-questions scope so a
    # stale cached form keeps its pre-fix redirect behavior instead of
    # silently dumping the user into a different tab.
    def inbox_kind
      return @inbox_kind if defined?(@inbox_kind)

      raw = params[:inbox_kind].to_s
      @inbox_kind = if params.key?(:inbox_kind)
        Inbox::Queue::KINDS.include?(raw) ? raw : nil
      else
        Inbox::Queue::CLARIFYING_QUESTIONS_KIND
      end
    end

    def inbox_redirect_params(selected_entry:, detail_view:)
      {
        project_id: inbox_scoped_project&.id,
        kind: inbox_kind,
        selected: selected_entry && helpers.inbox_selected_param(selected_entry),
        view: detail_view ? "detail" : nil
      }.compact
    end

    # Notice copy when the operator has finished their clarifying answer and
    # there is nothing else waiting in the scope they were browsing. On the
    # mixed "All" tab there may still be plan-review entries after, so the
    # wording is intentionally generic there.
    def inbox_drained_notice
      if inbox_kind.nil?
        "No more clarifying questions waiting in this view."
      else
        "You've completed the clarifying-questions queue."
      end
    end

    # The inbox form posts inside a Turbo Frame; on failure the redirect must
    # land inside the same frame so the user keeps their answers and the
    # pane scrolls back into view.
    def failure_redirect_path
      if inbox_mode?
        dashboard_inbox_path(**inbox_redirect_params(selected_entry: inbox_current_entry, detail_view: true))
      elsif queue_mode?
        project_issue_clarifying_questions_path(@project, @issue, queue_redirect_params)
      else
        project_issue_clarifying_questions_path(@project, @issue)
      end
    end

    def inbox_current_entry
      Inbox::Queue::Entry.new(
        kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
        record: @issue
      )
    end

    # @spec OPERATOR-INBOX-008
    # When the inbox form fails we redirect back into the same frame, which
    # otherwise renders every textarea empty. Stash the submitted answers in
    # a one-shot flash keyed by issue id so the inbox detail partial can
    # repopulate them in place instead of forcing the operator to retype.
    # The cookie session has a ~4KB ceiling, so we cap the payload and fall
    # back to the empty form (current behavior) if it would overflow rather
    # than risk corrupting the session.
    def remember_pending_inbox_answers
      return unless inbox_mode?
      return if @issue.blank?

      submitted = Array(params[:answers]).map { |answer| answer.to_s }
      return if submitted.empty?

      trimmed = submitted.map { |answer| answer.byteslice(0, MAX_PENDING_ANSWER_BYTES).scrub("") }
      return if trimmed.sum { |answer| ActiveSupport::JSON.encode(answer).bytesize } > MAX_PENDING_ANSWERS_BYTES

      pending = flash[:inbox_pending_answers] || {}
      pending[@issue.id.to_s] = trimmed
      flash[:inbox_pending_answers] = pending
    end
  end
end
