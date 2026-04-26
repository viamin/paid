# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Pagy::Method
  include Pundit::Authorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :with_current_attributes, prepend: true
  before_action :authenticate_user!
  after_action :verify_authorized, unless: :skip_pundit?
  after_action :verify_policy_scoped, if: :verify_policy_scoped?

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  def with_current_attributes
    Current.request_id = request.uuid

    if devise_controller?
      TenantContext.with_system_access { yield }
    else
      Current.user = rls_safe_current_user
      TenantContext.apply!(Current.user&.account)
      yield
    end
  ensure
    TenantContext.clear!
    Current.reset
  end

  def rls_safe_current_user
    TenantContext.with_system_access do
      current_user.tap { |user| user&.account }
    end
  end

  def current_account
    Current.account
  end
  helper_method :current_account

  def feature_enabled?(flag_name, project: nil)
    FeatureFlags.enabled?(flag_name, project:)
  end
  helper_method :feature_enabled?

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back(fallback_location: root_path)
  end

  def skip_pundit?
    devise_controller? || is_a?(HomeController) || is_a?(DashboardController) || is_a?(QualityDashboardsController)
  end

  def verify_policy_scoped?
    action_name == "index" && !skip_pundit?
  end
end
