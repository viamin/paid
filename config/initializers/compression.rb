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

# Insert after Rack::Sendfile (always present) so compression works regardless
# of whether ActionDispatch::Static is in the middleware stack.
Rails.configuration.middleware.insert_after Rack::Sendfile, Rack::Deflater, deflater_options
