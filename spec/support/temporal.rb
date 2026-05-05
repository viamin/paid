# frozen_string_literal: true

# Eager-load the Temporalio::Client class so that instance_double
# references in specs can verify against the real interface.
# The production initializer (config/initializers/temporal.rb) loads
# this lazily, but RSpec's verifying doubles need the constant at
# define-time.
require "temporalio/client"
