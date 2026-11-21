# frozen_string_literal: true

module Development
  module PgHeroOverview
    # Orchestrates one overview scan: collect findings, update persisted
    # observation state, then file/update/close GitHub issues through the
    # shared filer. The scheduled job and the manual rake entry point both
    # run this class, so verification always exercises the same path.
    #
    # @spec RAILS-CONTROL-PLANE-025 RAILS-CONTROL-PLANE-026 RAILS-CONTROL-PLANE-027
    #   RAILS-CONTROL-PLANE-028 RAILS-CONTROL-PLANE-029
    class Scan
      Result = Data.define(:skipped, :created, :updated, :reopened, :closed, :deferred,
        :deferred_keys, :incomplete_categories, :findings) do
        def self.skipped_result
          new(skipped: true, created: 0, updated: 0, reopened: 0, closed: 0, deferred: 0,
            deferred_keys: [], incomplete_categories: [], findings: 0)
        end

        def self.from_filing(collection, filing)
          new(skipped: false, created: filing.created, updated: filing.updated,
            reopened: filing.reopened, closed: filing.closed, deferred: filing.deferred,
            deferred_keys: filing.deferred_keys,
            incomplete_categories: collection.incomplete_categories, findings: collection.findings.size)
        end

        def skipped? = skipped

        def complete? = incomplete_categories.empty?
      end

      def initialize(project:, client: nil, environment: Rails.env, database: nil,
        collector: nil, dashboard_base_url: nil, now: -> { Time.current })
        @project = project
        @environment = environment.to_s
        @database = database
        @collector = collector
        @dashboard_base_url = dashboard_base_url
        @now = now
        resolved_client = client || project.client
        @client = quiet_client(resolved_client) || resolved_client
      end

      def call
        return Result.skipped_result unless @environment == "development"

        # The filer needs a working GitHub client; a silent nil here would
        # turn "cannot file" into an apparent all-clear scan.
        raise ArgumentError, "No GitHub client for project #{@project.full_name}" if @client.nil?

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        collection = collector.call
        rows = StateStore.new(now: @now).record(collection.findings)
        StateStore.new(now: @now).reset_unobserved(rows)
        actionable = collection.findings.select do |finding|
          !finding.persistence_required || rows[finding.key].consecutive_observations >= Policy::PERSISTENCE_ROUNDS
        end
        filing = IssueFiler.new(project: @project, client: @client,
          dashboard_base_url: @dashboard_base_url, now: @now).sync(
            observed_findings: collection.findings,
            actionable_findings: actionable,
            rows: rows,
            collected_categories: collection.coverage.select { |_, status| status == :collected }.keys.to_set)

        result = Result.from_filing(collection, filing)
        log_scan(result, duration_ms: elapsed_ms(started_at))
        result
      end

      private

      def collector
        @collector ||= Collect.new(environment: @environment, database: @database, now: @now)
      end

      # Respect quiet mode exactly like the other self-repo filers: comment
      # notifications are suppressed; body updates and lifecycle transitions
      # still happen.
      def quiet_client(client)
        return nil unless client && @project.respond_to?(:quiet_mode?) && @project.quiet_mode?

        GithubClient::CommentSuppressing.new(client)
      end

      def log_scan(result, duration_ms:)
        level = result.complete? ? :info : :warn
        Rails.logger.public_send(level,
          message: result.complete? ? "pghero_overview.scan_completed" : "pghero_overview.scan_incomplete",
          project_id: @project.id,
          findings: result.findings,
          created: result.created,
          updated: result.updated,
          reopened: result.reopened,
          closed: result.closed,
          deferred: result.deferred,
          incomplete_categories: result.incomplete_categories,
          duration_ms: duration_ms)
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end
    end
  end
end
