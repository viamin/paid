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
    elsif current_account.suspended? && mutating_request?
      handle_suspended_account
    end
  end

  def handle_deactivated_account
    sign_out(current_user) if respond_to?(:sign_out)
    redirect_to new_user_session_path, alert: "This account has been deactivated. Please contact support."
  end

  def handle_suspended_account
    redirect_back(
      fallback_location: root_path,
      alert: "This account is suspended. Write operations are disabled."
    )
  end

  def mutating_request?
    !request.get? && !request.head?
  end

  def skip_tenant_enforcement?
    devise_controller?
  end
end
