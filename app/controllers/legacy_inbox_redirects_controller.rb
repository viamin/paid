# frozen_string_literal: true

class LegacyInboxRedirectsController < ApplicationController
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    redirect_to legacy_target_path, status: :moved_permanently
  end

  def show
    redirect_to legacy_target_path(entry_id: legacy_selected_entry_id), status: :moved_permanently
  end

  private

  def legacy_target_path(entry_id: legacy_selected_entry_id)
    destination = entry_id.present? ? inbox_entry_path(entry_id) : inbox_path
    query = inbox_query_params.to_query
    query.present? ? "#{destination}?#{query}" : destination
  end

  def inbox_query_params
    {
      project_id: params[:project_id].presence,
      kind: valid_inbox_kind
    }.compact
  end

  def valid_inbox_kind
    kind = params[:kind].to_s
    Inbox::Queue::KINDS.include?(kind) ? kind : nil
  end

  def legacy_selected_entry_id
    selected = params[:selected].to_s
    return selected if selected.present?

    kind = params[:entry_kind].to_s
    record_id = params[:entry_id].to_s
    return if kind.blank? || record_id.blank?

    "#{kind}:#{record_id}"
  end
end
