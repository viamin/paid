# frozen_string_literal: true

module Database
  class QueryMonitor
    IGNORED_NAMES = %w[SCHEMA TRANSACTION CACHE].freeze
    MAX_SQL_LENGTH = 500
    DEFAULT_SLOW_QUERY_MS = 250
    DEFAULT_REPEATED_SELECT_THRESHOLD = 5

    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        request = ActionDispatch::Request.new(env)
        QueryMonitor.instrument("request", path: request.path, method: request.request_method) do
          @app.call(env)
        end
      end
    end

    class << self
      def install!
        return if @installed

        ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          current&.record(payload)
        end
        @installed = true
      end

      def instrument(label, metadata = {})
        previous = current
        self.current = new(label: label, metadata: metadata)
        yield
      ensure
        current&.flush
        self.current = previous
      end

      def current
        Thread.current[:database_query_monitor]
      end

      private

      def current=(monitor)
        Thread.current[:database_query_monitor] = monitor
      end
    end

    def initialize(label:, metadata: {})
      @label = label
      @metadata = metadata
      @repeated_selects = Hash.new do |hash, key|
        hash[key] = { count: 0, duration_ms: 0.0, sql: nil }
      end
    end

    def record(payload)
      return if ignored?(payload)

      duration_ms = payload[:duration].to_f
      sql = payload[:sql].to_s

      log_slow_query(sql, duration_ms) if duration_ms >= slow_query_ms
      record_select(sql, duration_ms) if sql.match?(/\ASELECT/i)
    end

    def flush
      repeated_selects.each_value do |entry|
        next if entry[:count] < repeated_select_threshold

        Rails.logger.warn(
          message: "database.query.repeated_select",
          component: "database",
          query_context: label,
          query_count: entry[:count],
          total_duration_ms: entry[:duration_ms].round(1),
          sql: summarize(entry[:sql]),
          **metadata
        )
      end
    end

    private

    attr_reader :label, :metadata, :repeated_selects

    def ignored?(payload)
      IGNORED_NAMES.include?(payload[:name]) || payload[:cached]
    end

    def record_select(sql, duration_ms)
      fingerprint = fingerprint(sql)
      entry = repeated_selects[fingerprint]
      entry[:count] += 1
      entry[:duration_ms] += duration_ms
      entry[:sql] ||= sql
    end

    def log_slow_query(sql, duration_ms)
      Rails.logger.warn(
        message: "database.query.slow",
        component: "database",
        query_context: label,
        duration_ms: duration_ms.round(1),
        sql: summarize(sql),
        **metadata
      )
    end

    def fingerprint(sql)
      sql.squish
        .gsub(/'(?:''|[^'])*'/, "?")
        .gsub(/\b\d+\b/, "?")
        .gsub(/\s+/, " ")
    end

    def summarize(sql)
      summary = sql.squish
      return summary if summary.length <= MAX_SQL_LENGTH

      "#{summary.first(MAX_SQL_LENGTH)}..."
    end

    def slow_query_ms
      Integer(ENV.fetch("DATABASE_SLOW_QUERY_MS", DEFAULT_SLOW_QUERY_MS))
    end

    def repeated_select_threshold
      Integer(ENV.fetch("DATABASE_REPEATED_SELECT_THRESHOLD", DEFAULT_REPEATED_SELECT_THRESHOLD))
    end
  end
end
