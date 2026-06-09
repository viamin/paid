# frozen_string_literal: true

return if Rails.env.test?

require_relative "../../lib/paid/exception_notifier"

ExceptionNotification.configure do |config|
  config.ignored_exceptions += %w[
    ActionController::RoutingError
    ActiveRecord::RecordNotFound
    ActionController::InvalidAuthenticityToken
    ActionController::BadRequest
  ]

  config.add_notifier :paid, Paid::ExceptionNotifier.new
end

# Insert the notifier *inside* ShowExceptions (closer to the app). ShowExceptions
# rescues exceptions from the middleware it wraps and renders an error page
# without re-raising, so a notifier placed outside it would never see production
# 500s. Placing it after ShowExceptions lets it rescue, notify, and re-raise
# before ShowExceptions renders the response.
Rails.application.config.middleware.insert_after(
  ActionDispatch::ShowExceptions,
  ExceptionNotification::Rack
)
