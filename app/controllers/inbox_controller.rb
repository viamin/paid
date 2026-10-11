# frozen_string_literal: true

class InboxController < ApplicationController
  before_action :authenticate_user!
  before_action :load_inbox, only: %i[index show open_chat]

  # @spec OPERATOR-INBOX-001 @spec OPERATOR-INBOX-003
  def index
    @selected_entry = @inbox_entries.first
    @detail_view = false
  end

  # Task-oriented operator guide linked from the partial-closeout pane (#4189).
  # @spec PARTIAL-CLOSEOUT-022
  def partial_closeout_guide
  end

  # @spec OPERATOR-INBOX-003 @spec OPERATOR-INBOX-009
  def show
    @selected_entry = resolve_selected_entry(@inbox_entries)
    return redirect_to(inbox_path(**inbox_redirect_params), status: :see_other) unless @selected_entry

    @detail_view = true
    render :index
  end

  # @spec QUESTION-EXPLORATION-001 @spec QUESTION-EXPLORATION-014
  def open_chat
    entry = resolve_selected_entry(@inbox_entries)
    raise ActiveRecord::RecordNotFound unless entry

    chat_session = Inbox::OpenInteractiveChat.call(user: current_user, entry:)
    respond_to do |format|
      format.html { redirect_to chat_session_path(chat_session) }
      format.json { render json: { id: chat_session.id, url: chat_session_path(chat_session) }, status: :created }
    end
  end

  # Lazy-loaded by the top-level nav badge Turbo Frame so ordinary page
  # renders never build the full Inbox::Queue.
  # @spec OPERATOR-INBOX-010
  def count
    @inbox_count = Inbox::Count.call(user: current_user)
  end

  private

  # @spec INBOX-FOUNDATION-009 @spec INBOX-FOUNDATION-010 @spec INBOX-FOUNDATION-011
  def load_inbox
    @scoped_project = scoped_needs_input_project
    @selected_kind = valid_inbox_kind
    @selected_sort = valid_inbox_sort
    @inbox_availability = Inbox::Availability.call(user: current_user, project: @scoped_project, kind: @selected_kind)
    @inbox_projects = @inbox_availability.available_projects
    @inbox_entries = Inbox::Queue.call(user: current_user, project: @scoped_project, kind: @selected_kind, sort: @selected_sort)
    redirect_for_empty_filtered_combination
  end

  # A filter combination with no matching items would otherwise render the
  # same "Inbox clear" empty state as a genuinely empty inbox, with no
  # explanation that widening the filters would surface items. Falls back to
  # the fully unfiltered view (keeping only `sort`) rather than guessing at
  # the "nearest" non-empty combination (#4276).
  def redirect_for_empty_filtered_combination
    return if @inbox_entries.present?
    return if @selected_kind.nil? && @scoped_project.nil?
    return if @inbox_availability.total_count.zero?

    redirect_to inbox_path(sort: params[:sort].presence), status: :see_other,
      notice: "No inbox items matched that filter, so it was cleared. Showing every open item instead."
  end

  def scoped_needs_input_project
    return if params[:project_id].blank?

    project = policy_scope(Project).find(params[:project_id])
    authorize project, :show?
    project
  end

  def valid_inbox_kind
    kind = params[:kind].to_s
    Inbox::Queue::KINDS.include?(kind) ? kind : nil
  end

  def valid_inbox_sort
    sort = params[:sort].to_s
    Inbox::Queue::SORTS.key?(sort) ? sort : Inbox::Queue::DEFAULT_SORT
  end

  def inbox_redirect_params
    { project_id: @scoped_project&.id, kind: @selected_kind, sort: params[:sort].presence }.compact
  end

  def resolve_selected_entry(entries)
    requested_id = params[:entry_id].to_s
    entries.find { |entry| entry.id == requested_id }
  end
end
