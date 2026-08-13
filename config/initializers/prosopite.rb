# frozen_string_literal: true

return unless Rails.env.development?

require "prosopite/middleware/rack"

Rails.application.config.after_initialize do
  Prosopite.rails_logger = true
end

Rails.application.config.middleware.use(Prosopite::Middleware::Rack)
