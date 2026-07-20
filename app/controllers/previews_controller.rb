# frozen_string_literal: true

class PreviewsController < ApplicationController
  include AuditLogging

  before_action :set_preview_session, only: [ :show, :stop ]

  # GET /previews/:id — renders the iframe wrapper that embeds the proxied app.
  # The proxied content itself is served by the PreviewsProxy middleware at
  # /previews/:token/*. Both this wrapper page and the proxied path require an
  # authenticated, authorized user; the iframe URL embeds the proxy path.
  def show
    authorize @preview_session
  end

  # POST /projects/:project_id/preview_sessions/:id/stop
  def stop
    authorize @preview_session, :stop?

    @preview_session.update!(status: "stopped")
    audit_event("preview.stopped", metadata: { preview_session_id: @preview_session.id })
    redirect_to @preview_session.project, notice: "Preview stopped."
  end

  private

  def set_preview_session
    @preview_session = policy_scope(PreviewSession).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    # Mirror the proxy's 404 posture: do not reveal session existence.
    redirect_to root_path, alert: "Preview not found."
  end

  def resolve_audit_subject
    @preview_session
  end
end
