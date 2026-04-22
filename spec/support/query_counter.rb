# frozen_string_literal: true

module QueryCounter
  IGNORED_QUERY_NAMES = %w[SCHEMA TRANSACTION CACHE].freeze

  def count_queries
    count = 0
    callback = lambda do |*, payload|
      next if IGNORED_QUERY_NAMES.include?(payload[:name]) || payload[:cached]

      count += 1
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    count
  end

  def capture_queries
    queries = []
    callback = lambda do |*, payload|
      next if IGNORED_QUERY_NAMES.include?(payload[:name]) || payload[:cached]

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    queries
  end
end

RSpec.configure do |config|
  config.include QueryCounter
end
