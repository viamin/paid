# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Collects every addressable finding category the installed PgHero
    # Overview renders — including its extended view — using PgHero's Ruby
    # methods with the Overview's thresholds. Database errors propagate so a
    # failed collector is visible; catalog reads that time out mark their
    # category incomplete instead of pretending it was observed clean.
    #
    # @spec RAILS-CONTROL-PLANE-025 RAILS-CONTROL-PLANE-029
    class Collect
      Result = Data.define(:findings, :coverage, :skipped, :database_id) do
        def initialize(findings:, coverage:, skipped: false, database_id: nil)
          super(findings: findings, coverage: coverage, skipped: skipped, database_id: database_id)
        end

        def self.skipped_result
          new(findings: [], coverage: {}, skipped: true, database_id: nil)
        end

        def skipped? = skipped

        def complete? = !skipped && coverage.values.all? { |status| status == :collected }

        def incomplete_categories = coverage.select { |_, status| status != :collected }.keys
      end

      IDLE_IN_TRANSACTION_THRESHOLD = 100
      SEQUENCE_DANGER_THRESHOLD = 0.9
      TRANSACTION_ID_DANGER_THRESHOLD = 1_500_000_000
      REPLICATION_LAG_THRESHOLD_SECONDS = 5
      SUGGESTED_INDEX_MIN_AVERAGE_TIME = 20.0
      SUGGESTED_INDEX_MIN_CALLS = 50
      QUERY_STATS_WINDOW = 3.hours
      QUERY_TEXT_LIMIT = 1_000
      SLOW_QUERY_TEXT_LIMIT = 16_000

      def initialize(environment: Rails.env, database: nil, now: -> { Time.current })
        @environment = environment.to_s
        @database = database
        @now = now
      end

      def call
        return Result.skipped_result unless @environment == "development"

        require "pghero"
        require "pg_query"

        findings = []
        coverage = {}
        collect_replication(findings, coverage)
        collect_long_running(findings, coverage)
        collect_connections(findings, coverage)
        collect_maintenance(findings, coverage)
        collect_constraints(findings, coverage)
        collect_sequences(findings, coverage)
        indexes = collect_indexes(findings, coverage)
        query_stats = collect_query_stats(findings, coverage)
        collect_suggested_indexes(findings, coverage, query_stats: query_stats, indexes: indexes)
        collect_extended(findings, coverage)

        Result.new(findings: findings, coverage: coverage, skipped: false, database_id: database.id.to_s)
      end

      private

      attr_reader :now

      def database
        @database ||= PgHero.databases.fetch(:primary)
      end

      def collect_replication(findings, coverage)
        if database.replica?
          lag = database.replication_lag
          if lag && lag >= REPLICATION_LAG_THRESHOLD_SECONDS
            add_finding(findings, type: :replication_lag, key: "replication_lag",
              title: "Replication lag #{lag.round(1)}s",
              observed: { lag_seconds: lag.round(1), threshold_seconds: REPLICATION_LAG_THRESHOLD_SECONDS })
          end
        else
          database.replication_slots.reject { |slot| slot[:active] }.each do |slot|
            add_finding(findings, type: :replication_slot, key: "replication_slot/#{slot.fetch(:slot_name)}",
              title: "Inactive replication slot #{slot.fetch(:slot_name)}",
              observed: { slot_name: slot.fetch(:slot_name), database: slot[:database], active: false })
          end
        end
        coverage[:replication] = :collected
      end

      def collect_long_running(findings, coverage)
        coverage[:long_running] = :collected
        # Autovacuum workers are expected maintenance (documented exclusion).
        database.long_running_queries
          .reject { |query| query[:backend_type] == "autovacuum worker" }
          .each do |query|
            text = filtered_query(query[:query])
            next if text.blank?

            duration_sec = (query[:duration_ms].to_f / 1000.0).round(1)
            add_finding(findings, type: :long_running_query, key: "long_running_query/#{Digest::SHA256.hexdigest(text)}",
              title: "Long-running query (#{duration_text(duration_sec)})",
              observed: { query: text, duration_sec: duration_sec,
                          threshold_sec: database.long_running_query_sec, state: query[:state] })
          end
      end

      def collect_connections(findings, coverage)
        coverage[:connections] = :collected
        states = database.connection_states
        total = states.values.sum
        idle_in_transaction = states["idle in transaction"].to_i
        threshold = database.total_connections_threshold

        if total >= threshold
          add_finding(findings, type: :connection_pressure, key: "connection_pressure",
            title: "Total connections #{total} at/above threshold",
            observed: { total_connections: total, threshold: threshold })
        end

        return unless idle_in_transaction >= IDLE_IN_TRANSACTION_THRESHOLD

        add_finding(findings, type: :idle_in_transaction, key: "idle_in_transaction",
          title: "#{idle_in_transaction} idle-in-transaction connections",
          observed: { idle_in_transaction: idle_in_transaction, threshold: IDLE_IN_TRANSACTION_THRESHOLD })
      end

      def collect_maintenance(findings, coverage)
        coverage[:maintenance] = :collected
        database.transaction_id_danger(threshold: TRANSACTION_ID_DANGER_THRESHOLD).each do |danger|
          add_finding(findings, type: :xid_danger, key: "xid_danger/#{danger.fetch(:schema)}/#{danger.fetch(:table)}",
            title: "Transaction ID wraparound danger on #{danger.fetch(:schema)}.#{danger.fetch(:table)}",
            observed: { table: "#{danger.fetch(:schema)}.#{danger.fetch(:table)}",
                        transactions_left: danger[:transactions_left],
                        threshold: TRANSACTION_ID_DANGER_THRESHOLD })
        end
      end

      def collect_constraints(findings, coverage)
        coverage[:constraints] = :collected
        database.invalid_constraints.each do |constraint|
          add_finding(findings, type: :invalid_constraint, key: "invalid_constraint/#{constraint.fetch(:schema)}/#{constraint.fetch(:name)}",
            title: "Invalid constraint #{constraint.fetch(:name)} on #{constraint.fetch(:schema)}.#{constraint.fetch(:table)}",
            observed: { table: "#{constraint.fetch(:schema)}.#{constraint.fetch(:table)}",
                        constraint: constraint.fetch(:name) })
        end
      end

      def collect_sequences(findings, coverage)
        sequences, timed_out = rescue_timeout([]) { database.sequences }
        coverage[:sequences] = timed_out ? :timeout : :collected
        return [] if timed_out

        sequences.partition { |sequence| sequence[:readable] }.then do |readable, unreadable|
          unreadable.each do |sequence|
            add_finding(findings, type: :unreadable_sequence, key: "unreadable_sequence/#{sequence.fetch(:table)}/#{sequence.fetch(:column)}",
              title: "Unreadable sequence #{sequence.fetch(:sequence)}",
              observed: { table: sequence.fetch(:table), column: sequence.fetch(:column),
                          sequence: sequence.fetch(:sequence) })
          end
          database.sequence_danger(threshold: SEQUENCE_DANGER_THRESHOLD, sequences: readable).each do |sequence|
            add_finding(findings, type: :sequence_danger, key: "sequence_danger/#{sequence.fetch(:table)}/#{sequence.fetch(:column)}",
              title: "Sequence #{sequence.fetch(:sequence)} at #{percent_used(sequence)}% of max",
              observed: { table: sequence.fetch(:table), column: sequence.fetch(:column),
                          sequence: sequence.fetch(:sequence), last_value: sequence[:last_value],
                          max_value: sequence[:max_value], threshold_pct: (SEQUENCE_DANGER_THRESHOLD * 100).round })
          end
        end
      end

      # @spec RAILS-CONTROL-PLANE-040
      def collect_indexes(findings, coverage)
        indexes, timed_out = rescue_timeout([]) { database.indexes }
        coverage[:indexes] = timed_out ? :timeout : :collected
        return nil if timed_out

        database.invalid_indexes(indexes: indexes).each do |index|
          add_finding(findings, type: :invalid_index, key: "invalid_index/#{index.fetch(:schema)}/#{index.fetch(:name)}",
            title: "Invalid index #{index.fetch(:name)} on #{index.fetch(:schema)}.#{index.fetch(:table)}",
            observed: { schema: index.fetch(:schema), table: index.fetch(:table), index: index.fetch(:name), valid: false })
        end
        table_indexes = indexes.group_by { |index| index.values_at(:schema, :table) }.transform_values do |entries|
          entries.sort_by { |index| index.fetch(:name) }.map { |index| index.slice(:name, :definition, :valid, :unique) }
        end
        database.duplicate_indexes(indexes: indexes).each do |pair|
          unneeded = pair.fetch(:unneeded_index)
          covering = pair.fetch(:covering_index)
          add_finding(findings, type: :duplicate_index, key: "duplicate_index/#{unneeded.fetch(:schema)}/#{unneeded.fetch(:name)}",
            title: "Duplicate index #{unneeded.fetch(:name)} covered by #{covering.fetch(:name)}",
            observed: { table: "#{unneeded.fetch(:schema)}.#{unneeded.fetch(:table)}",
                        unneeded_index: unneeded.fetch(:name), covering_index: covering.fetch(:name),
                        unneeded_definition: unneeded[:definition], covering_definition: covering[:definition],
                        unneeded_valid: unneeded[:valid], covering_valid: covering[:valid],
                        unneeded_unique: unneeded[:unique], covering_unique: covering[:unique],
                        table_indexes: table_indexes.fetch(unneeded.values_at(:schema, :table), []) }.compact)
        end
        indexes
      end

      # @spec RAILS-CONTROL-PLANE-025 RAILS-CONTROL-PLANE-038
      def collect_query_stats(findings, coverage)
        unless database.query_stats_enabled?
          coverage[:query_stats] = :unavailable
          add_finding(findings, type: :query_stats_unavailable, key: "query_stats_unavailable",
            title: "PgHero query stats unavailable",
            observed: { reason: "pg_stat_statements not installed or not readable",
                        fix: "Install the extension (bin/setup provisions it) so slow-query detection works." })
          return nil
        end

        coverage[:query_stats] = :collected
        stats = database.query_stats(historical: true, start_at: now.call - QUERY_STATS_WINDOW)
        # PgHero combines current counters with retained interval samples for
        # the window, so slow_queries already judges repeated slowness rather
        # than lifetime cumulative totals (counter resets are absorbed).
        database.slow_queries(query_stats: stats).each do |query|
          text = filtered_query(query[:query], limit: nil)
          add_finding(findings, type: :slow_query, key: "slow_query/#{query.fetch(:query_hash)}",
            title: "Slow query: avg #{query[:average_time].round(1)} ms over #{query[:calls]} calls",
            observed: {
              query: text&.truncate_bytes(SLOW_QUERY_TEXT_LIMIT),
              query_truncated: text.to_s.bytesize > SLOW_QUERY_TEXT_LIMIT, average_ms: query[:average_time].round(1), calls: query[:calls],
              threshold_ms: database.slow_query_ms, threshold_calls: database.slow_query_calls,
              window_hours: QUERY_STATS_WINDOW.to_i / 3600
            })
        end
        stats
      end

      def collect_suggested_indexes(findings, coverage, query_stats:, indexes:)
        if query_stats.nil?
          coverage[:suggested_indexes] = :unavailable
          return
        end
        if indexes.nil?
          coverage[:suggested_indexes] = :timeout
          return
        end

        coverage[:suggested_indexes] = :collected
        eligible = query_stats.select do |stat|
          stat[:average_time] >= SUGGESTED_INDEX_MIN_AVERAGE_TIME && stat[:calls] >= SUGGESTED_INDEX_MIN_CALLS
        end
        by_query = database.suggested_indexes_by_query(query_stats: eligible, indexes: indexes)
        database.suggested_indexes(suggested_indexes_by_query: by_query).each do |suggestion|
          columns = suggestion.fetch(:columns).join(",")
          add_finding(findings, type: :suggested_index, key: "suggested_index/#{suggestion.fetch(:table)}/#{columns}",
            title: "Suggested index on #{suggestion.fetch(:table)} (#{columns})",
            observed: { table: suggestion.fetch(:table), columns: suggestion.fetch(:columns),
                        queries: Array(suggestion[:queries]).filter_map { |q| filtered_query(q) }.first(3) })
        end
      end

      def collect_extended(findings, coverage)
        coverage[:extended] = :collected
        threshold_pct = database.cache_hit_rate_threshold

        { table: database.table_hit_rate, index: database.index_hit_rate }.each do |kind, rate|
          # A nil rate means the counters have no data yet — insufficient
          # evidence, not a finding.
          next if rate.nil?
          next unless rate < threshold_pct / 100.0

          add_finding(findings, type: :cache_hit_rate, key: "cache_hit_rate/#{kind}",
            title: "#{kind.capitalize} cache hit rate #{(rate * 100).round(1)}% below threshold",
            observed: { "#{kind}_rate_pct".to_sym => (rate * 100).round(1), threshold_pct: threshold_pct })
        end

        database.unused_indexes(max_scans: 0, min_size: database.unused_index_bytes).each do |index|
          add_finding(findings, type: :unused_index, key: "unused_index/#{index.fetch(:schema)}/#{index.fetch(:index)}",
            title: "Unused index #{index.fetch(:index)} (#{index[:size_bytes]} bytes)",
            observed: { table: "#{index.fetch(:schema)}.#{index.fetch(:table)}", index: index.fetch(:index),
                        size_bytes: index.fetch(:size_bytes), index_scans: index[:index_scans],
                        threshold_bytes: database.unused_index_bytes })
        end
      end

      def add_finding(findings, type:, key:, title:, observed:)
        findings << Finding.new(
          type: type, key: key, title: title, observed: observed,
          observed_at: now.call, database: database.id.to_s,
          persistence_required: Policy.persistence_required?(type),
          category: Policy.category_for(type)
        )
      end

      def filtered_query(text, limit: QUERY_TEXT_LIMIT)
        return nil if text.blank?

        filtered = Development::PgHeroQueryText.call(text.to_s)
        limit ? filtered.truncate(limit) : filtered
      end

      def percent_used(sequence)
        return 0 unless sequence[:last_value] && sequence[:max_value].to_f.positive?

        ((sequence[:last_value] / sequence[:max_value].to_f) * 100).round
      end

      def duration_text(duration_sec)
        duration_sec >= 60 ? "#{(duration_sec / 60).round(1)} min" : "#{duration_sec.round(1)} s"
      end

      # Mirrors the Overview controller's statement-timeout rescue so a
      # locked catalog read marks the category incomplete instead of raising.
      def rescue_timeout(default)
        [ yield, false ]
      rescue ActiveRecord::LockWaitTimeout, ActiveRecord::QueryCanceled
        [ default, true ]
      end
    end
  end
end
