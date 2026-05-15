# frozen_string_literal: true

Avo.configure do |config|
  config.root_path = "/admin"
  config.app_name = "Paid Operator Console"
  config.home_path = "/admin/resources/accounts"
  config.current_user_method = :current_user
  config.authorization_client = :pundit
  config.explicit_authorization = true
  config.license_key = ENV["AVO_LICENSE_KEY"] if ENV["AVO_LICENSE_KEY"].present?

  config.authenticate_with do
    user = warden.authenticate(scope: :user)
    unless user
      redirect_to main_app.new_user_session_path
      next
    end

    next if user.operator?

    redirect_to main_app.root_path, alert: "You are not authorized to access the operator console."
  end
end

Rails.configuration.to_prepare do
  Avo::ApplicationController.include(OperatorConsole::RequestContext) unless Avo::ApplicationController < OperatorConsole::RequestContext
end
