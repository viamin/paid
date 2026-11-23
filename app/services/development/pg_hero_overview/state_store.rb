# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Persists per-finding observation continuity. Persistence gating and
    # recurrence need observation history that survives process restarts, so
    # counters live in the pghero_overview_findings table (system
    # infrastructure, like the PgHero history tables) rather than a cache.
    #
    # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-028
    class StateStore
      def initialize(project:, now: -> { Time.current })
        @project = project
        @now = now
      end

      # Records one observation per finding, returning the rows keyed by
      # finding key. A gap longer than PgHeroOverviewFinding::STALE_AFTER
      # restarts the persistence count — the scanner was off, so consecutive
      # observations are not really consecutive.
      def record(findings)
        findings.to_h do |finding|
          row = findings_scope.find_or_create_by!(database: finding.database, finding_key: finding.key) do |new_row|
            new_row.finding_type = finding.type.to_s
            new_row.first_seen_at = @now.call
            new_row.last_seen_at = @now.call
            new_row.consecutive_observations = 0
          end
          row.finding_type = finding.type.to_s
          row.first_seen_at = @now.call if row.first_seen_at.nil?
          row.consecutive_observations = stale?(row) ? 1 : row.consecutive_observations + 1
          row.last_seen_at = @now.call
          row.save!
          [ finding.key, row ]
        end
      end

      # Findings not observed this scan lose their consecutive count so a
      # later single observation cannot masquerade as persistence. Tracked
      # issue linkage is kept: it is what makes reopen-on-recurrence work.
      def reset_unobserved(observed_rows)
        findings_scope.where.not(id: observed_rows.values.map(&:id))
          .where("consecutive_observations > 0")
          .in_batches.update_all(consecutive_observations: 0)
        nil
      end

      private

      def findings_scope
        PgHeroOverviewFinding.where(project: @project)
      end

      def stale?(row)
        row.last_seen_at.present? && row.last_seen_at < PgHeroOverviewFinding::STALE_AFTER.ago
      end
    end
  end
end
