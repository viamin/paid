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
    entry = bounded_entry
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

  # @spec INBOX-FOUNDATION-009 @spec INBOX-FOUNDATION-010 @spec INBOX-FOUNDATION-011
  # @spec OPERATOR-INBOX-016
  def load_inbox
    @scoped_project = scoped_needs_input_project
    @scoped_projects = scoped_inbox_projects
    @scoped_project = @scoped_projects.first if @scoped_projects.one?
    @selected_kinds = valid_inbox_kinds
    @selected_kind = @selected_kinds.first if @selected_kinds.one?
    @inbox_query = inbox_search_query
    @selected_sort = valid_inbox_sort
    @selected_scope = valid_inbox_scope
    if single_entry_request?
      @inbox_entries = selected_entry_queue
      return
    end
    if stale_show_request?
      @inbox_entries = []
      return
    end

    @inbox_entries = inbox_queue.call
    load_inbox_presentations(entries: @inbox_entries)
    redirect_for_empty_filtered_combination
  end

  # Filters, counts, and the project list a list rendering needs. The unfiltered
  # index passes its already-built entries so counts match the list exactly; a
  # single-entry render derives the matrix so the filter dialog still offers
  # every project with items.
  def load_inbox_presentations(entries: nil)
    if entries && @scoped_projects.empty? && @selected_kinds.empty? && @inbox_query.empty? && @selected_scope == Inbox::Queue::ACTIONABLE_SCOPE
      @inbox_availability = Inbox::Availability.call(user: current_user, entries:)
    else
      @inbox_availability = Inbox::Availability.call(
        user: current_user, projects: @scoped_projects, kinds: @selected_kinds, scope: @selected_scope
      )
    end
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

  # A request that resolves one selected entry: every `show` variant — the
  # turbo-frame detail pane and the full-page render alike — plus the
  # chat/supplement/history entry points.
  def selected_entry_request?
    single_entry_request? || action_name == "show"
  end

  # A full-page `show` of a link that no longer resolves can only redirect,
  # so the bounded lookup's miss skips the list build — and the escalated-PR
  # materialization that redirect used to pay for (#5165). The frame variant
  # already returned through `single_entry_request?`.
  # @spec OPERATOR-INBOX-002C @spec OPERATOR-INBOX-015
  def stale_show_request?
    action_name == "show" && bounded_entry.nil?
  end

  def selected_entry_queue
    [ bounded_entry ].compact
  end

  # Bounded, authorized resolution of the one entry a selected-entry request
  # targets: the parsed record ID keeps stale, hidden, and removed direct
  # links on ID-scoped lane queries instead of materializing the lane — for
  # escalated PRs, every matching blocked PR (#5165).
  # @spec OPERATOR-INBOX-002C @spec OPERATOR-INBOX-015
  def bounded_entry
    # An id without a record component can never match an entry, so skip the
    # lookup instead of materializing the kind's unbounded lane.
    return if selected_entry_record_id.blank?

    @bounded_entry ||= Inbox::Queue.new(user: current_user, projects: @scoped_projects,
      kinds: selected_entry_kinds, record_id: selected_entry_record_id).find_entry(params[:entry_id])
  end

  def selected_entry_kinds
    @selected_kinds.presence || [ params[:entry_id].to_s.split(":", 2).first ]
  end

  def inbox_queue
    # Unbounded on full-page shows: a valid direct link still renders the
    # whole filtered list beside its detail pane, so only single-entry
    # renders (whose ranking context reuses this queue) bound it.
    @inbox_queue ||= Inbox::Queue.new(user: current_user, projects: @scoped_projects,
      kinds: queue_entry_kinds, sort: @selected_sort, scope: @selected_scope, query: @inbox_query,
      record_id: single_entry_request? ? selected_entry_record_id : nil)
  end

  def queue_entry_kinds
    single_entry_request? ? selected_entry_kinds : @selected_kinds
  end

  def selected_entry_record_id
    return unless selected_entry_request?

    # @spec OPERATOR-INBOX-002C OPERATOR-INBOX-015
    params[:entry_id].to_s.split(":", 2).second
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
    return if @selected_kinds.empty? && @scoped_projects.empty? && @inbox_query.empty?
    return if @inbox_availability.total_count.zero?

    redirect_to inbox_path(sort: params[:sort].presence, scope: params[:scope].presence), status: :see_other,
      notice: "No inbox items matched that filter, so it was cleared. Showing every open item instead."
  end

  def scoped_needs_input_project
    scoped_inbox_projects.first if scoped_inbox_projects.one?
  end

  def scoped_inbox_projects
    @scoped_inbox_projects ||= begin
      ids = Array(params[:project_ids]).presence || Array(params[:project_id]).presence || []
      policy_scope(Project).where(id: ids).tap { |projects| projects.each { |project| authorize project, :show? } }.to_a
    end
  end

  def valid_inbox_kinds
    values = Array(params[:kinds]).presence || Array(params[:kind]).presence || []
    values.map(&:to_s).intersection(Inbox::Queue::KINDS)
  end

  def inbox_search_query
    query = params[:q]
    query.is_a?(ActionController::Parameters) ? query.permit(:text_cont).to_h : {}
  end

  def valid_inbox_sort
    sort = params[:sort].to_s
    Inbox::Queue::SORTS.key?(sort) ? sort : Inbox::Queue::DEFAULT_SORT
  end

  def inbox_redirect_params
    {
      project_ids: params[:project_ids],
      project_id: params[:project_id],
      kinds: params[:kinds],
      kind: params[:kind],
      q: @inbox_query.presence,
      sort: params[:sort].presence,
      scope: @selected_scope == Inbox::Queue::ACTIONABLE_SCOPE ? nil : @selected_scope
    }.compact
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
