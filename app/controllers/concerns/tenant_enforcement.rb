# frozen_string_literal: true

# Enforces tenant lifecycle status on controller actions.
# Suspended accounts get read-only access; deactivated accounts are blocked entirely.
#
# Include in ApplicationController after authentication:
#   include TenantEnforcement
module TenantEnforcement
  extend ActiveSupport::Concern

  included do
    before_action :enforce_tenant_status, unless: :skip_tenant_enforcement?
  end

  private

  def enforce_tenant_status
    return unless current_account

    if current_account.deactivated?
      handle_deactivated_account
    elsif current_account.suspended? && mutating_request? && !allow_suspended_account_write?
      handle_suspended_account
    end
  end

  def handle_deactivated_account
    message = "This account has been deactivated. Please contact support."
    terminate_deactivated_session
    # Use 401 (not 403) — the account's credentials are revoked, not merely insufficient
    return render json: { error: message }, status: :unauthorized if request.format.json?
    return render_sse_tenant_block(message, status: :unauthorized) if sse_request?

    redirect_to new_user_session_path, alert: message
  end

  def handle_suspended_account
    respond_to_tenant_block(
      fallback_location: root_path,
      message: "This account is suspended. Write operations are disabled."
    )
  end

  def mutating_request?
    !request.get? && !request.head?
  end

  def respond_to_tenant_block(fallback_location:, message:)
    if request.format.json?
      render_json_tenant_block(message)
    elsif request.format.turbo_stream?
      redirect_back_safely(fallback_location, alert: message, status: :see_other)
    elsif sse_request?
      render_sse_tenant_block(message)
    else
      redirect_back_safely(fallback_location, alert: message)
    end
  end

  def render_json_tenant_block(message)
    render json: { error: message }, status: :forbidden
  end

  def render_sse_tenant_block(message, status: :forbidden)
    response.headers["Content-Type"] = "text/event-stream"
    render plain: %(event: error\ndata: #{ { error: message }.to_json }\n\n), status: status
  end

  def sse_request?
    request.format == Mime[:event_stream] || request.headers["Accept"]&.include?("text/event-stream")
  end

  def terminate_deactivated_session
    return unless current_user

    if request.format.json? || sse_request?
      reset_session
    elsif respond_to?(:sign_out)
      sign_out(current_user)
    end
  end

  def skip_tenant_enforcement?
    devise_controller?
  end

  def allow_suspended_account_write?
    false
  end
end
