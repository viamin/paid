# frozen_string_literal: true

require Rails.root.join("lib/paid/json_log_formatter")

Rails.application.configure do
  next unless ENV["PAID_LOG_FORMAT"] == "json"

  config.log_tags = [ :request_id ] if config.log_tags.blank?

  logger = ActiveSupport::Logger.new($stdout)
  logger.formatter = Paid::JsonLogFormatter.new
  config.logger = logger
end
