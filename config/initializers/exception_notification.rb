# frozen_string_literal: true

return if Rails.env.test?

ExceptionNotification.configure do |config|
  config.ignored_exceptions += %w[
    ActionController::RoutingError
    ActiveRecord::RecordNotFound
    ActionController::InvalidAuthenticityToken
    ActionController::BadRequest
  ]

  config.add_notifier :paid, Paid::ExceptionNotifier.new
end

Rails.application.config.middleware.insert_before(
  ActionDispatch::ShowExceptions,
  ExceptionNotification::Rack
)
