# frozen_string_literal: true

require_relative "base"
require_relative "collector_queries"

module Knowledge
  module Quality
    # Surfaces collectors whose latest completed run indexed an older commit
    # than the project's most recently indexed version. Re-collection is
    # overdue for that collector; severity is warning because staleness here
    # usually reflects an upstream collection gap, not user-visible drift.
    #
    # Collector types whose runs are pinned to a synthetic project version
    # (Knowledge::SessionSummaries::SyncKnowledgeArtifact and
    # ChangeIntents::SyncKnowledgeArtifact both create one-per-record) are
    # excluded: their "staleness against HEAD" is structural — they don't
    # read from git, and their synthetic `committed_at` will rarely line up
    # with a real HEAD timestamp. Flagging them would produce permanent
    # noise the operator can't act on, since re-collection creates a fresh
    # synthetic version alongside the existing one rather than updating it.
    class Checks::StaleCollector < Checks::Base
      include Checks::CollectorQueries

      code "stale_collector"
      severity "warning"

      def collect_findings(collector)
        latest = latest_project_version
        return unless latest

        latest_runs.each do |type, run|
          next unless run.status == "completed"
          next if synthetic_branch?(run)
          next unless run.project_version&.committed_at
          next unless run.project_version.committed_at < latest.committed_at

          add_finding(
            collector,
            target_type: "Collector",
            target_id: type,
            detail: "latest run indexed at #{run.project_version.commit_sha.first(7)}, " \
                    "HEAD is #{latest.commit_sha.first(7)}",
            extra: { collector_run_id: run.id }
          )
        end
      end

      private

      def latest_runs
        @latest_runs ||= latest_collector_runs_by_type
      end

      def synthetic_branch?(run)
        SYNTHETIC_BRANCHES.include?(run.project_version&.branch)
      end
    end
  end
end
