# frozen_string_literal: true

class InboxController < ApplicationController
  before_action :authenticate_user!
  before_action :load_inbox, only: %i[index show supplement history]

  # @spec OPERATOR-INBOX-001 @spec OPERATOR-INBOX-003 @spec OPERATOR-INBOX-025
  def index
    flash.keep if turbo_frame_request_id == "inbox-detail"
    @selected_entry = @inbox_entries.first
    @detail_view = false
  end

  # Task-oriented operator guide linked from the partial-closeout pane (#4189).
  # @spec PARTIAL-CLOSEOUT-022
  def partial_closeout_guide
  end

  # @spec OPERATOR-INBOX-003 @spec OPERATOR-INBOX-009
  def show
    @selected_entry = resolve_selected_entry(@inbox_entries) || hidden_or_removed_entry
    return redirect_to(inbox_path(**inbox_redirect_params), status: :see_other) unless @selected_entry

    load_root_prerequisite_ranking
    @detail_view = true
    return render(:show) if detail_frame_request?

    render :index
  end

  # An authorized user may inspect a request that phase relevance or their own
  # removal moved out of the default list.
  # @spec INBOX-PHASE-RELEVANCE-003
  def hidden_or_removed_entry
    entry = Inbox::Queue.find_entry(user: current_user, entry_id: params[:entry_id])
    entry = nil unless Inbox::RansackQuery.call(entries: [ entry ].compact, params: @inbox_query).present?
    @inbox_entries = [ entry ].compact if entry
    entry
  end

  # @spec QUESTION-EXPLORATION-001 @spec QUESTION-EXPLORATION-014
  def open_chat
    chat_session = Inbox::OpenInteractiveChat.call(
      user: current_user,
      entry_id: params[:entry_id]
    )
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

  # @spec OPERATOR-INBOX-017
  def supplement
    @selected_entry = resolve_selected_entry(@inbox_entries)
  end

  # @spec OPERATOR-INBOX-025
  def history
    @selected_entry = resolve_selected_entry(@inbox_entries)
  end

  # @spec INBOX-PHASE-RELEVANCE-006
  def remove_entry
    entry = removable_entry
    return redirect_back_to_inbox(alert: "That inbox item is no longer available.") unless entry

    Inbox::Removals::Remove.call(entry:, user: current_user)
    redirect_back_to_inbox(notice: "Removed from your inbox. The work and its history are unchanged.")
  end

  # @spec INBOX-PHASE-RELEVANCE-006
  def restore_entry
    entry = removable_entry
    return redirect_back_to_inbox(alert: "That inbox item is no longer available.") unless entry

    Inbox::Removals::Restore.call(entry:, user: current_user)
    redirect_back_to_inbox(notice: "Restored to your inbox.")
  end

  # @spec LAYERED-VERIFY-015 LAYERED-VERIFY-016 LAYERED-VERIFY-018
  def decide_layered_verification_finding
    entry = Inbox::Queue.find_entry(user: current_user, entry_id: params[:entry_id])
    return redirect_to(inbox_path, alert: "That verification finding is no longer available.") unless entry&.layered_verification_finding?

    authorize entry.project, :manage_issues?
    decision = params.require(:decision).permit(:action, :reason, :external_revision)
    Inbox::DecideLayeredVerificationFinding.call(finding: entry.record, user: current_user, **decision.to_h.symbolize_keys)
    redirect_to inbox_entry_path(entry.id), notice: "Verification finding decision recorded. No repair was started."
  rescue Inbox::DecideLayeredVerificationFinding::StaleRevisionError, ArgumentError => error
    redirect_to inbox_entry_path(params[:entry_id]), alert: error.message
  end

  private

  # Direct links resolve in any scope, so an item moved out of the default list
  # by phase relevance or personal removal stays inspectable.
  # @spec INBOX-PHASE-RELEVANCE-003
  def removable_entry
    Inbox::Queue.find_entry(user: current_user, entry_id: params[:entry_id])
  end

  def redirect_back_to_inbox(alert: nil, notice: nil)
    target = inbox_path(inbox_redirect_params)
    alert ? redirect_to(target, alert:) : redirect_to(target, notice:)
  end

  # @spec INBOX-FOUNDATION-009 @spec INBOX-FOUNDATION-010 @spec INBOX-FOUNDATION-011 OPERATOR-INBOX-016 OPERATOR-INBOX-028
  def load_inbox
    @inbox_query = inbox_query
    @selected_project_ids = selected_project_ids
    @selected_kinds = selected_kinds
    @selected_sort = valid_inbox_sort
    @selected_scope = valid_inbox_scope
    if single_entry_request?
      @inbox_entries = selected_entry_queue
      return
    end

    @unfiltered_inbox_entries = inbox_queue.call
    @inbox_entries = Inbox::RansackQuery.call(entries: @unfiltered_inbox_entries, params: @inbox_query)
    load_inbox_presentations(entries: @unfiltered_inbox_entries)
    redirect_for_empty_filtered_combination
  end

  # Filters, counts, and the project list a list rendering needs. The unfiltered
  # index passes its already-built entries so counts match the list exactly; a
  # single-entry render derives the matrix so the filter dialog still offers
  # every project with items.
  def load_inbox_presentations(entries: nil)
    @inbox_availability = Inbox::Availability.call(user: current_user, entries:, projects: @selected_project_ids,
      kinds: @selected_kinds)
    @inbox_projects = @inbox_availability.available_projects
  end

  # @spec OPERATOR-INBOX-015
  def detail_frame_request?
    action_name == "show" && turbo_frame_request_id == "inbox-detail"
  end

  # A request that renders exactly one entry: the turbo-frame detail pane and
  # the chat/supplement entry points.
  def single_entry_request?
    detail_frame_request? || %w[open_chat supplement history].include?(action_name)
  end

  def selected_entry_queue
    entry = Inbox::Queue.find_entry(user: current_user, entry_id: params[:entry_id])
    Inbox::RansackQuery.call(entries: [ entry ].compact, params: @inbox_query)
  end

  def inbox_queue
    @inbox_queue ||= Inbox::Queue.new(user: current_user, sort: @selected_sort, scope: @selected_scope)
  end

  # @spec INBOX-PHASE-RELEVANCE-002
  def valid_inbox_scope
    scope = params[:scope].to_s
    Inbox::Queue::SCOPES.include?(scope) ? scope : Inbox::Queue::ACTIONABLE_SCOPE
  end

  # A filter combination with no matching items would otherwise render the
  # same "Inbox clear" empty state as a genuinely empty inbox, with no
  # explanation that widening the filters would surface items. Falls back to
  # the fully unfiltered view (keeping only `sort`) rather than guessing at
  # the "nearest" non-empty combination (#4276).
  def redirect_for_empty_filtered_combination
    return if @inbox_entries.present?
    return unless @selected_kinds.present? || @selected_project_ids.present?
    return if @inbox_availability.total_count.zero?
    return if Inbox::RansackQuery.call(entries: @unfiltered_inbox_entries,
      params: @inbox_query.except("search_cont")).present?

    redirect_to inbox_path(sort: params[:sort].presence, scope: params[:scope].presence,
      q: @inbox_query.slice("search_cont").presence), status: :see_other,
      notice: "No inbox items matched that filter, so it was cleared. Showing every open item instead."
  end

  def inbox_query
    query = params.fetch(:q, {}).permit(:search_cont, kind_in: [], project_id_in: []).to_h
    query["kind_in"] ||= [ params[:kind] ] if params[:kind].present?
    query["project_id_in"] ||= [ params[:project_id] ] if params[:project_id].present?
    query
  end

  def selected_project_ids
    @inbox_query.fetch("project_id_in", []).filter_map { |id| Integer(id, exception: false) }
  end

  def selected_kinds
    @inbox_query.fetch("kind_in", []).select { |kind| Inbox::Queue::KINDS.include?(kind) }
  end

  def valid_inbox_sort
    sort = params[:sort].to_s
    Inbox::Queue::SORTS.key?(sort) ? sort : Inbox::Queue::DEFAULT_SORT
  end

  def inbox_redirect_params
    query = params[:q].present? ? { q: @inbox_query.presence } : { project_id: params[:project_id].presence, kind: params[:kind].presence }
    query.merge(
      sort: params[:sort].presence,
      scope: @selected_scope == Inbox::Queue::ACTIONABLE_SCOPE ? nil : @selected_scope
    ).compact
  end

  def resolve_selected_entry(entries)
    requested_id = params[:entry_id].to_s
    entries.find { |entry| entry.id == requested_id }
  end

  # @spec PARTIAL-CLOSEOUT-048
  def load_root_prerequisite_ranking
    return unless @selected_entry.partial_closeout?

    queue_issue_ids = ranking_queue_entries.filter_map { |entry| entry.issue&.id if entry.partial_closeout? }
    @root_prerequisite_ranking = Issues::RootPrerequisiteRanking.call(
      account: @selected_entry.project.account, queue_issue_ids:, visible_project_ids: inbox_queue.visible_project_ids
    )
  end

  def ranking_queue_entries
    action_name == "index" ? @inbox_entries : inbox_queue.call
  end
end
