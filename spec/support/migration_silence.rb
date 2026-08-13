# frozen_string_literal: true

# Migration specs under spec/migrations/ drive ActiveRecord::Migration up/down
# directly, which defaults to verbose mode and prints "-- add_column ... ->
# 0.0042s" lines across the test log output. Silence it — the specs assert
# behavior, not DDL output — so rspec runs stay readable.
RSpec.configure do |config|
  config.around(type: :migration) do |example|
    previous = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    example.run
  ensure
    ActiveRecord::Migration.verbose = previous
  end

  # Auto-tag specs under spec/migrations/ so the hook above fires without
  # every migration spec needing to add `type: :migration` by hand.
  config.define_derived_metadata(file_path: %r{/spec/migrations/}) do |metadata|
    metadata[:type] ||= :migration
  end
end
