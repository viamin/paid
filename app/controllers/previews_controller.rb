# frozen_string_literal: true

require "net/http"

class PreviewsController < ApplicationController
  include AuditLogging

  COPYABLE_PROXY_RESPONSE_HEADERS = %w[
    cache-control
    content-language
    etag
    expires
    last-modified
    vary
  ].freeze

  skip_after_action :verify_authorized, only: :show
  before_action :set_preview_session, only: :stop

  def show
    return show_token_preview if request.path_parameters[:token].present?

    show_wrapper
  end

  def stop
    authorize @preview_session, :stop?

    @preview_session.mark_stopped!
    audit_event("preview.stopped", metadata: { preview_session_id: @preview_session.id })

    redirect_to @preview_session.project, notice: "Preview stopped."
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
    @preview_session = PreviewSession.find_accessible_by_token(request.path_parameters[:token])
    return show_wrapper_fallback if @preview_session.nil? && params[:path].blank? && request.path_parameters[:token].match?(/\A\d+\z/)
    return head :not_found unless @preview_session && policy(@preview_session).show?

    apply_embed_headers
    @preview_session.touch_last_active!
    proxy_preview_request
  rescue Errno::ECONNREFUSED, SocketError, Net::ReadTimeout, EOFError => e
    render plain: "Preview is unavailable: #{e.message}", status: :bad_gateway
  end

  def apply_embed_headers
    response.headers["Content-Security-Policy"] = "frame-ancestors 'self'"
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
  end

  def proxy_preview_request
    upstream = preview_uri
    http = Net::HTTP.new(upstream.host, upstream.port)
    http.open_timeout = 2
    http.read_timeout = 5

    upstream_response = http.get(upstream.request_uri)
    response.status = upstream_response.code.to_i
    response.content_type = upstream_response.content_type if upstream_response.content_type.present?
    copy_proxy_headers(upstream_response)
    self.response_body = upstream_response.body
  end

  def preview_uri
    path = params[:path].to_s

    URI::HTTP.build(
      host: "127.0.0.1",
      port: @preview_session.tunnel_port,
      path: path.present? ? "/#{path}" : "/",
      query: request.query_string.presence
    )
  end

  def copy_proxy_headers(upstream_response)
    upstream_response.each_header do |key, value|
      next unless COPYABLE_PROXY_RESPONSE_HEADERS.include?(key)

      response.headers[key] = value
    end
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
