# frozen_string_literal: true

module Database
  # Analyzes query patterns and identifies optimization opportunities.
  #
  # Collects statistics about query execution during a block and produces
  # an analysis report with recommendations for missing indexes, N+1
  # patterns, and slow queries.
  #
  # @example
  #   report = Database::QueryAnalyzer.analyze("dashboard") do
  #     Project.all.includes(:agent_runs).map(&:recent_runs)
  #   end
  #   report[:recommendations].each { |r| puts r }
  class QueryAnalyzer
    N_PLUS_ONE_THRESHOLD = 3
    SLOW_QUERY_MS = 100

    class Collector
      attr_reader :queries

      def initialize
        @queries = []
      end

      def record(payload)
        return if ignored?(payload)

        @queries << {
          sql: payload[:sql],
          name: payload[:name],
          duration_ms: payload[:duration].to_f,
          cached: payload[:cached] || false
        }
      end

      private

      def ignored?(payload)
        %w[SCHEMA TRANSACTION CACHE].include?(payload[:name])
      end
    end

    def self.analyze(label = "analysis", &block)
      new(label: label).analyze(&block)
    end

    def initialize(label: "analysis")
      @label = label
      @collector = Collector.new
    end

    def analyze
      subscribe_to_queries
      result = yield

      analysis = build_analysis
      log_analysis(analysis)
      { result: result, analysis: analysis }
    ensure
      unsubscribe
    end

    private

    attr_reader :label, :collector, :subscriber

    def subscribe_to_queries
      @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, started, finished, _id, payload|
        collector.record(payload.merge(duration: (finished - started) * 1000))
      end
    end

    def unsubscribe
      ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
    end

    def build_analysis
      queries = collector.queries
      slow = slow_queries(queries)
      n_plus_one = detect_n_plus_one(queries)
      {
        label: label,
        total_queries: queries.size,
        total_duration_ms: queries.sum { |q| q[:duration_ms] }.round(1),
        slow_queries: slow,
        n_plus_one_candidates: n_plus_one,
        query_distribution: query_distribution(queries),
        recommendations: build_recommendations(queries, slow_queries: slow, n_plus_one: n_plus_one)
      }
    end

    def slow_queries(queries)
      queries.select { |q| q[:duration_ms] >= SLOW_QUERY_MS }.map do |q|
        { sql: truncate_sql(q[:sql]), duration_ms: q[:duration_ms].round(1) }
      end
    end

    def detect_n_plus_one(queries)
      fingerprints = Hash.new(0)
      queries.each do |q|
        next unless q[:sql].to_s.match?(/\ASELECT/i)

        fp = fingerprint(q[:sql])
        fingerprints[fp] += 1
      end

      fingerprints.select { |_, count| count >= N_PLUS_ONE_THRESHOLD }.map do |fp, count|
        { fingerprint: truncate_sql(fp), count: count }
      end
    end

    def query_distribution(queries)
      queries.group_by { |q| query_type(q[:sql]) }
             .transform_values(&:size)
    end

    def build_recommendations(queries, slow_queries:, n_plus_one:)
      recs = []

      recs << "#{slow_queries.size} slow queries detected (>#{SLOW_QUERY_MS}ms). Consider adding indexes." if slow_queries.any?

      if n_plus_one.any?
        recs << "#{n_plus_one.size} potential N+1 query patterns detected. Consider using includes/preload."
      end

      if queries.size > 20
        recs << "High query count (#{queries.size}). Consider batching or eager loading."
      end

      recs << "No issues detected." if recs.empty?
      recs
    end

    def fingerprint(sql)
      sql.to_s.squish
         .gsub(/'(?:''|[^'])*'/, "?")
         .gsub(/\b\d+\b/, "?")
         .gsub(/\s+/, " ")
    end

    def query_type(sql)
      case sql.to_s.strip
      when /\ASELECT/i then "SELECT"
      when /\AINSERT/i then "INSERT"
      when /\AUPDATE/i then "UPDATE"
      when /\ADELETE/i then "DELETE"
      else "OTHER"
      end
    end

    def truncate_sql(sql)
      return sql if sql.to_s.length <= 200

      "#{sql.to_s[0, 200]}..."
    end

    def log_analysis(analysis)
      Rails.logger.info(
        message: "database.query_analysis",
        component: "database",
        label: analysis[:label],
        total_queries: analysis[:total_queries],
        total_duration_ms: analysis[:total_duration_ms],
        slow_query_count: analysis[:slow_queries].size,
        n_plus_one_count: analysis[:n_plus_one_candidates].size
      )
    end
  end
end
