# frozen_string_literal: true

class PreviewsController < ApplicationController
  include AuditLogging

  skip_after_action :verify_authorized, only: :show
  before_action :set_preview_session, only: :stop

  def show
    return show_token_preview if request.path_parameters[:token].present?

    show_wrapper
  end

  def stop
    authorize @preview_session, :stop?

    Previews::Lifecycle.stop_session!(preview_session: @preview_session, terminal_status: "stopped")
    audit_event("preview.stopped", metadata: { preview_session_id: @preview_session.id })

    redirect_to @preview_session.project, notice: "Preview stopped."
  rescue Previews::Lifecycle::Error => e
    redirect_to @preview_session.project, alert: "Preview stop failed: #{e.message}"
  end

  private

  def show_wrapper
    @preview_session = policy_scope(PreviewSession).find(params[:id])
    authorize @preview_session
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Preview not found."
  end

  # @spec LIVE-PREVIEW-004
  def show_token_preview
    return show_wrapper_fallback if params[:path].blank? && request.path_parameters[:token].match?(/\A\d+\z/)

    head :not_found
  end

  def show_wrapper_fallback
    @preview_session = policy_scope(PreviewSession).find(request.path_parameters[:token])
    authorize @preview_session
    render :show
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Preview not found."
  end

  def set_preview_session
    @preview_session = policy_scope(PreviewSession).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: "Preview not found."
  end

  def resolve_audit_subject
    @preview_session
  end
end
