# frozen_string_literal: true

class AccountAuditLogsController < ApplicationController
  include AccountAdministrationPage

  before_action :load_account_administration_page

  def index
    authorize current_account, :show?

    @q = current_account.account_activity_events
      .includes(:actor)
      .recent
      .ransack(params[:q])

    @q.sorts = "created_at desc" if @q.sorts.empty?
    @pagy, @events = pagy(@q.result)
  end

  def export
    authorize current_account, :show?

    events = current_account.account_activity_events
      .includes(:actor)
      .recent
      .ransack(params[:q])
      .result
      .limit(10_000)

    respond_to do |format|
      format.json do
        send_data events_to_json(events),
          filename: "audit_export_#{Time.current.strftime('%Y%m%d_%H%M%S')}.json",
          type: :json
      end
      format.csv do
        send_data events_to_csv(events),
          filename: "audit_export_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv",
          type: "text/csv"
      end
    end
  end

  private

  def events_to_json(events)
    events.map { |e|
      {
        id: e.id,
        action: e.action,
        actor: e.actor_label,
        description: e.description,
        subject_type: e.subject_type,
        subject_id: e.subject_id,
        metadata: e.metadata,
        created_at: e.created_at.iso8601
      }
    }.to_json
  end

  def events_to_csv(events)
    require "csv"
    CSV.generate do |csv|
      csv << %w[id action actor description subject_type subject_id metadata created_at]
      events.each do |e|
        csv << [ e.id, e.action, e.actor_label, e.description, e.subject_type, e.subject_id,
                 e.metadata.to_json, e.created_at.iso8601 ]
      end
    end
  end
end
