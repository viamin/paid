# frozen_string_literal: true

class InboxController < ApplicationController
  before_action :authenticate_user!
  before_action :load_inbox, only: %i[index show]

  # @spec OPERATOR-INBOX-001 @spec OPERATOR-INBOX-003
  def index
    @selected_entry = @inbox_entries.first
    @detail_view = false
  end

  # @spec OPERATOR-INBOX-003 @spec OPERATOR-INBOX-009
  def show
    @selected_entry = resolve_selected_entry(@inbox_entries)
    return redirect_to(inbox_path(project_id: @scoped_project&.id, kind: @selected_kind), status: :see_other) unless @selected_entry

    @detail_view = true
    render :index
  end

  # Lazy-loaded by the top-level nav badge Turbo Frame so ordinary page
  # renders never build the full Inbox::Queue.
  # @spec OPERATOR-INBOX-010
  def count
    @inbox_count = Inbox::Count.call(user: current_user)
  end

  private

  def load_inbox
    @scoped_project = scoped_needs_input_project
    @selected_kind = valid_inbox_kind
    @inbox_entries = Inbox::Queue.call(user: current_user, project: @scoped_project, kind: @selected_kind)
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

  def resolve_selected_entry(entries)
    requested_id = params[:entry_id].to_s
    entries.find { |entry| entry.id == requested_id }
  end
end
