# frozen_string_literal: true

module Development
  class PgHeroHistory
    LOCK_KEY = 1_357_180_090

    module IntervalCapture
      def reset_query_stats(user: nil, query_hash: nil, raise_errors: false)
        raise ArgumentError, "Only database-wide capture is supported" if user || query_hash

        execute("SELECT paid_diagnostics.reset_query_stats()")
        true
      end

      private

      def insert_query_stats(stats, captured_at)
        filtered = stats.map do |stat|
          stat.merge(query: PgHeroQueryText.call(stat.fetch(:query)))
        end
        super(filtered, captured_at)
      end
    end

    def initialize(environment: Rails.env, database: nil)
      @environment = environment.to_s
      @database = database
    end

    # @spec RAILS-CONTROL-PLANE-020 RAILS-CONTROL-PLANE-022
    def capture_queries
      collect do
        database.extend(IntervalCapture)
        database.capture_query_stats(raise_errors: true)
      end
    end

    # @spec RAILS-CONTROL-PLANE-021
    def capture_space
      collect { database.capture_space_stats }
    end

    # @spec RAILS-CONTROL-PLANE-021
    def clean_history
      collect do
        PgHero::Stats.transaction do
          database.clean_query_stats(before: 14.days.ago)
          database.clean_space_stats(before: 14.days.ago)
          retained = PgHero::QueryStats.where.not(query_id: nil).select(:query_id)
          PgHero::Query.where.not(id: retained).delete_all
        end
      end
    end

    private

    def database
      @database ||= PgHero.databases.fetch(:primary)
    end

    def collect
      return unless @environment == "development"

      require "pghero"
      require "pg_query"
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        acquired = connection.select_value("SELECT pg_try_advisory_lock(#{LOCK_KEY})")
        begin
          yield if acquired
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{LOCK_KEY})") if acquired
        end
      end
    end
  end
end
