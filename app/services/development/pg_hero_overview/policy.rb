# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Classification policy for every category the PgHero Overview renders.
    # Structural defects (broken indexes, invalid constraints, sequence
    # capacity, and friends) are actionable on first observation; transient
    # local activity and cumulative-counter readings must persist across
    # consecutive scans before an issue is filed. Informational exclusions
    # are recorded with their reasons so coverage is auditable.
    #
    # @spec RAILS-CONTROL-PLANE-025 RAILS-CONTROL-PLANE-028
    module Policy
      # Transient categories: one observation proves nothing — a single
      # long-running query, a connection burst, or a cold-start cache rate
      # is normal development noise.
      TRANSIENT_TYPES = %i[
        long_running_query connection_pressure idle_in_transaction cache_hit_rate replication_lag
      ].freeze

      # Structural categories: stable identities, no persistence round needed.
      STRUCTURAL_TYPES = %i[
        slow_query suggested_index invalid_index invalid_constraint duplicate_index
        unused_index sequence_danger unreadable_sequence xid_danger
        replication_slot query_stats_unavailable
      ].freeze

      # Consecutive scans a transient finding must be observed on before an
      # issue is filed.
      PERSISTENCE_ROUNDS = 2

      # Upper bound on new issues created by a single scan. Deferred findings
      # keep their accumulated state and are retried by the next scan.
      MAX_NEW_ISSUES_PER_RUN = 5

      # Coverage category owning each finding type; a category that could not
      # be observed this scan never has its issues closed.
      CATEGORY_BY_TYPE = {
        long_running_query: :long_running,
        connection_pressure: :connections,
        idle_in_transaction: :connections,
        xid_danger: :maintenance,
        invalid_constraint: :constraints,
        sequence_danger: :sequences,
        unreadable_sequence: :sequences,
        invalid_index: :indexes,
        duplicate_index: :indexes,
        slow_query: :query_stats,
        suggested_index: :suggested_indexes,
        query_stats_unavailable: :query_stats,
        unused_index: :extended,
        cache_hit_rate: :extended,
        replication_slot: :replication,
        replication_lag: :replication
      }.freeze

      # Documented informational exclusions: categories the Overview renders
      # that deliberately never file an issue, with the reason.
      INFORMATIONAL_EXCLUSIONS = {
        replication_lag: "The development database is a primary; the Overview's replica-only lag check does not apply.",
        autovacuum_long_running_queries: "Autovacuum workers appearing among long-running queries are expected maintenance."
      }.freeze

      module_function

      def persistence_required?(type)
        TRANSIENT_TYPES.include?(type)
      end

      def category_for(type)
        CATEGORY_BY_TYPE.fetch(type)
      end
    end
  end
end
