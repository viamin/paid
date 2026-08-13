# frozen_string_literal: true

require "webmock/rspec"

# Disable all external HTTP connections in tests
WebMock.disable_net_connect!(allow_localhost: true)
