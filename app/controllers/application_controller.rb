# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Pagy::Method
  include Pundit::Authorization
  include TenantEnforcement

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  around_action :with_current_attributes, prepend: true
  before_action :authenticate_user!
  before_action :stamp_cable_auth_cookie, if: :user_signed_in?
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

  # ActionCable websocket requests bypass the Warden/session middleware, so the
  # connection can't read request.env["warden"]. Stamp an encrypted user-id
  # cookie on every authenticated request so ApplicationCable::Connection can
  # authorize the subscriber (see app/channels/application_cable/connection.rb).
  # httponly denies JS access (defense vs. XSS exfiltration); secure scopes it
  # to HTTPS where the app enforces SSL.
  def stamp_cable_auth_cookie
    cookies.encrypted[ApplicationCable::Connection::CABLE_USER_COOKIE] = {
      value: current_user.id,
      httponly: true,
      secure: Rails.application.config.force_ssl
    }
  end

  def feature_enabled?(flag_name, project: nil)
    FeatureFlags.enabled?(flag_name, project:)
  end
  helper_method :feature_enabled?

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    redirect_back_safely(root_path)
  end

  def skip_pundit?
    devise_controller? || is_a?(HomeController) || is_a?(DashboardController) || is_a?(QualityDashboardsController)
  end

  def verify_policy_scoped?
    action_name == "index" && !skip_pundit?
  end

  def redirect_back_safely(fallback_location, **options)
    redirect_to safe_back_location(fallback_location), allow_other_host: false, **options
  end

  def safe_back_location(fallback_location)
    referer = request.referer
    return fallback_location if referer.blank?

    uri = URI.parse(referer)
    return fallback_location unless uri.host == request.host

    path = uri.request_uri
    return fallback_location unless path&.start_with?("/")

    path
  rescue URI::InvalidURIError
    fallback_location
  end
end
