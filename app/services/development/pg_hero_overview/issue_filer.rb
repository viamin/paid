# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Files finding issues into the tenant's self repository and maintains
    # the one-issue-per-identity lifecycle: create with evidence, update on
    # changed evidence, reopen on recurrence (or a human close while the
    # finding persists), close when the finding disappears from a category
    # this scan could observe. The GitHub open-issue list is read before any
    # write, so a failed lookup aborts without filing or closing anything,
    # and open issues carrying the identity marker are adopted when local
    # state is missing — a retried or concurrent scan cannot duplicate.
    #
    # @spec RAILS-CONTROL-PLANE-027 RAILS-CONTROL-PLANE-028 RAILS-CONTROL-PLANE-029
    class IssueFiler
      LABEL = "pghero-overview"
      IDENTITY_MARKER = "pghero-overview-finding"
      FINGERPRINT_MARKER = "pghero-overview-fingerprint"
      DEFAULT_CAP = Policy::MAX_NEW_ISSUES_PER_RUN
      BODY_TEXT_LIMIT = 1_500

      Result = Data.define(:created, :updated, :reopened, :closed, :deferred, :deferred_keys)

      INVESTIGATION_PROMPTS = {
        slow_query: "Run EXPLAIN (ANALYZE, BUFFERS) locally for this shape (bind parameters are already " \
                    "filtered), confirm the plan and row estimates, and decide whether the query needs a " \
                    "tighter scope, batching, or a covering index. This is an investigation lead: measure " \
                    "before any schema change and verify with the focused test suite.",
        suggested_index: "Reproduce with EXPLAIN and confirm an index on these columns would actually be " \
                         "chosen. Treat the suggestion as a lead: validate with measurements before proposing " \
                         "a migration; do not create the index from this issue alone.",
        invalid_index: "Inspect the index build state (look for a failed CREATE INDEX CONCURRENTLY) and " \
                       "rebuild it deliberately, then confirm pg_index reports it valid.",
        invalid_constraint: "Identify why the constraint was left NOT VALID; either validate existing rows " \
                            "(VALIDATE CONSTRAINT) or drop it deliberately.",
        duplicate_index: "Confirm the covering relationship through the catalog before removing the " \
                         "unneeded index; drop only with a reviewed migration.",
        unused_index: "Check the index has genuinely been unused across a representative workload window " \
                      "(statistics reset on restart), then consider removal through a reviewed migration.",
        sequence_danger: "Check the sequence usage rate and, if genuine, widen the column type or reseed; " \
                         "verify headroom afterwards.",
        unreadable_sequence: "Restore sequence readability (privileges) so capacity monitoring works; the " \
                             "scanner cannot judge that sequence otherwise.",
        xid_danger: "Run VACUUM FREEZE (or aggressive autovacuum settings) on the listed relation and " \
                    "re-check the remaining transaction IDs.",
        replication_slot: "Drop the stale slot if its consumer is gone (retained WAL grows without bound), " \
                          "or restart the consumer.",
        long_running_query: "Inspect the statement (text is literal-filtered) and the session state; decide " \
                            "whether it is stuck and blocking others or legitimate long work, and whether a " \
                            "statement timeout should bound it.",
        connection_pressure: "Check pool sizing and connection sources (PgHero's Connections page); change " \
                             "the threshold or the pool deliberately.",
        idle_in_transaction: "Find the holders via pg_stat_activity (idle in transaction) and fix the code " \
                             "path that leaves transactions open.",
        cache_hit_rate: "Compare database memory against the working-set size; these counters are cumulative " \
                        "since reset, so confirm the rate is persistently low rather than cold-start noise.",
        replication_lag: "Inspect the replica's replay position and load; confirm the lag is sustained " \
                         "rather than a burst.",
        query_stats_unavailable: "Install the pg_stat_statements extension (bin/setup provisions it in " \
                                 "development) so slow-query detection works again."
      }.freeze

      def initialize(project:, client:, dashboard_base_url: nil, cap: DEFAULT_CAP, now: -> { Time.current })
        @project = project
        @client = client
        @dashboard_base_url = dashboard_base_url || ENV.fetch("PAID_PGHERO_BASE_URL", "http://localhost:3000")
        @cap = cap
        @now = now
      end

      def sync(observed_findings:, actionable_findings:, rows:, collected_categories:)
        open_issues = @client.issues(@project.full_name, labels: LABEL, state: "open")
        open_by_number = open_issues.to_h { |issue| [ issue.number.to_i, issue ] }
        adopt_marked_issues(open_issues, rows)

        actionable_keys = actionable_findings.map(&:key).to_set
        created = updated = reopened = 0

        observed_findings.each do |finding|
          row = rows[finding.key]
          issue_number = row&.github_issue_number

          if issue_number.nil?
            next unless actionable_keys.include?(finding.key)
            next unless created < @cap

            rows[finding.key] = create_issue_for(finding, row)
            created += 1
          elsif actionable_keys.include?(finding.key) && (row.resolved_at.present? || !open_by_number.key?(issue_number))
            reopen_issue(finding, row, issue_number)
            reopened += 1
          elsif refresh_issue_body(finding, row, issue_number, open_by_number[issue_number])
            updated += 1
          end
        end

        closed = close_disappeared(observed_keys: observed_findings.map(&:key).to_set,
          collected_categories: collected_categories)
        # Cap-deferred findings keep their state rows; the next scan retries
        # them, so nothing is dropped.
        deferred_keys = actionable_findings.filter_map { |f| f.key if rows[f.key]&.github_issue_number.nil? }

        Result.new(created: created, updated: updated, reopened: reopened, closed: closed,
          deferred: deferred_keys.size, deferred_keys: deferred_keys)
      end

      private

      def create_issue_for(finding, row)
        issue = @client.create_issue(@project.full_name,
          title: title_for(finding), body: body_for(finding), labels: issue_labels)
        row ||= PgHeroOverviewFinding.create!(
          database: finding.database, finding_key: finding.key, finding_type: finding.type.to_s,
          first_seen_at: @now.call, last_seen_at: @now.call, consecutive_observations: 1)
        row.update!(github_issue_number: issue.number, resolved_at: nil, issue_last_updated_at: @now.call)
        log(:created, finding: finding, issue_number: issue.number)
        row
      end

      def refresh_issue_body(finding, row, issue_number, issue)
        return false if issue.nil?
        return false if issue.body.to_s.include?("#{FINGERPRINT_MARKER}: #{finding.fingerprint}")

        @client.update_issue(@project.full_name, issue_number, body: body_for(finding))
        row.update!(github_issue_number: issue_number, issue_last_updated_at: @now.call)
        log(:updated, finding: finding, issue_number: issue_number)
        true
      end

      def reopen_issue(finding, row, issue_number)
        @client.update_issue(@project.full_name, issue_number, state: "open")
        @client.add_comment(@project.full_name, issue_number,
          "Finding observed again at #{finding.observed_at.utc.iso8601} — reopening.")
        row.update!(resolved_at: nil, issue_last_updated_at: @now.call)
        log(:reopened, finding: finding, issue_number: issue_number)
      end

      # Only categories this scan actually observed may have their issues
      # closed — a timed-out catalog read must not look like a resolution.
      def close_disappeared(observed_keys:, collected_categories:)
        closed = 0
        PgHeroOverviewFinding.open_issues.find_each do |row|
          next if observed_keys.include?(row.finding_key)
          next unless collected_categories.include?(Policy.category_for(row.finding_type.to_sym))

          @client.update_issue(@project.full_name, row.github_issue_number, state: "closed")
          @client.add_comment(@project.full_name, row.github_issue_number,
            "Finding no longer observed at #{@now.call.utc.iso8601}; last observed #{row.last_seen_at.utc.iso8601}.")
          row.update!(resolved_at: @now.call)
          log(:closed, finding_key: row.finding_key, issue_number: row.github_issue_number)
          closed += 1
        end
        closed
      end

      # Issues carrying our identity marker but no local row (state loss, or
      # a partially-completed prior run) are adopted instead of duplicated.
      def adopt_marked_issues(open_issues, rows)
        open_issues.each do |issue|
          identity = issue.body.to_s[/<!-- #{IDENTITY_MARKER}: (.+?) -->/, 1]
          next if identity.blank?

          database_id, key = identity.split("/", 2)
          next if key.blank? || rows.key?(key)

          row = PgHeroOverviewFinding.find_or_create_by!(database: database_id, finding_key: key) do |new_row|
            new_row.finding_type = key.split("/").first
            new_row.first_seen_at = @now.call
            new_row.last_seen_at = @now.call
            new_row.consecutive_observations = 1
          end
          row.update!(github_issue_number: issue.number, resolved_at: nil)
          rows[key] = row
          log(:adopted, finding_key: key, issue_number: issue.number)
        end
      end

      def issue_labels
        [ LABEL, @project.generated_label_name, @project.automation_label_name ].compact.uniq
      end

      def title_for(finding)
        "[pghero] #{finding.title}".truncate(255)
      end

      def body_for(finding)
        <<~BODY.strip
          <!-- #{IDENTITY_MARKER}: #{finding.identity} -->
          <!-- #{FINGERPRINT_MARKER}: #{finding.fingerprint} -->

          _Automatically filed by the development PgHero Overview scanner. This is an investigation lead, not an instruction to change the schema._

          **Finding type:** #{finding.type}
          **Database:** #{finding.database}
          **Observed at:** #{finding.observed_at.utc.iso8601}
          **Dashboard:** #{@dashboard_base_url}/pghero?database=#{finding.database}

          ## Observed values

          #{observed_sections(finding)}

          ## Investigation prompt

          #{INVESTIGATION_PROMPTS.fetch(finding.type, "Inspect the PgHero Overview entry for this finding.")}

          _Subsequent scans update this issue while the finding persists and close it when it disappears._
        BODY
      end

      def observed_sections(finding)
        finding.observed.reject { |key, _| key.to_s.start_with?("threshold") }.map do |key, value|
          render_observed(key, value, threshold_for(key, finding.observed))
        end.join("\n")
      end

      def render_observed(key, value, threshold)
        if value.is_a?(Array)
          lines = [ "- #{key}:" ]
          value.each { |item| lines << "  - #{render_value(item)}" }
          lines.join("\n")
        elsif threshold
          "- #{key}: #{render_value(value)} (threshold: #{render_value(threshold)})"
        else
          "- #{key}: #{render_value(value)}"
        end
      end

      def render_value(value)
        return value.inspect unless value.is_a?(String)
        return value if value.length <= 80 && !value.include?("\n")

        "\n  ```sql\n  #{value.truncate(BODY_TEXT_LIMIT).gsub("\n", "\n  ")}\n  ```"
      end

      # Joins a value with its sibling threshold key when one exists
      # (calls -> threshold_calls, average_ms -> threshold_ms,
      # total_connections -> threshold).
      def threshold_for(key, observed)
        unit = %w[_ms _calls _pct _bytes _sec _seconds].find do |suffix|
          key.to_s.end_with?(suffix) && key.to_s.length > suffix.length
        end
        candidates = [ :"threshold_#{key}" ]
        candidates << :"threshold#{unit}" if unit
        candidates << :threshold
        candidates.each do |candidate|
          value = observed[candidate]
          return value unless value.nil?
        end
        nil
      end

      def log(event, finding: nil, **payload)
        extra = finding ? { finding_type: finding.type, finding_key: finding.key } : {}
        Rails.logger.info(message: "pghero_overview.issue_#{event}", project_id: @project.id, **extra, **payload)
      end
    end
  end
end
