# frozen_string_literal: true

# Enable gzip compression for static assets and API responses.
# HTML is excluded to avoid BREACH-style attacks on pages with CSRF tokens.
#
# Deferred to an initializer so that environment-specific config (e.g.
# config.public_file_server.enabled) is already applied before we decide
# where to insert Rack::Deflater in the middleware stack.
deflater_options = {
  include: %w[application/javascript text/javascript text/css application/json image/svg+xml]
}

if Rails.configuration.public_file_server.enabled
  Rails.configuration.middleware.insert_before ActionDispatch::Static, Rack::Deflater, deflater_options
else
  Rails.configuration.middleware.use Rack::Deflater, deflater_options
end
