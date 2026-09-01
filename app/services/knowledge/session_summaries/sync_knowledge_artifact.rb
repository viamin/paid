# frozen_string_literal: true

module Knowledge
  module SessionSummaries
    # Syncs a captured AgentRunSessionSummary into the knowledge-artifact
    # pipeline so it becomes searchable and eligible for context-bundle
    # assembly. Mirrors ChangeIntents::SyncKnowledgeArtifact: a shared
    # synthetic project version/collector run per project holds every
    # summary's artifact, distinguished by scope_path/identifier.
    #
    # @spec SESSION-SUMMARY-003
    class SyncKnowledgeArtifact
      COLLECTOR_TYPE = "session_summary".freeze
      SYNTHETIC_BRANCH = "session-summaries".freeze

      attr_reader :session_summary

      def initialize(session_summary:)
        @session_summary = session_summary
      end

      def self.call(...)
        new(...).call
      end

      def call
        collector_run.mark_running! unless collector_run.status == "running"
        collector_run.update!(tool_version: collector.tool_version)

        count = Knowledge::ArtifactStore.new(project: project, collector_run: collector_run)
          .store_all([ collector.artifact_for(session_summary) ])

        collector_run.mark_completed!(count: count)
        KnowledgeArtifact.bust_artifact_counts_cache(project.id)
        count
      rescue StandardError => error
        collector_run.mark_failed!(error: error.message)
        raise
      end

      private

      def collector
        @collector ||= Knowledge::Collectors::SessionSummaryCollector.new(
          project: project,
          project_version: project_version,
          collector_run: collector_run,
          options: {}
        )
      end

      def collector_run
        @collector_run ||= CollectorRun.create_or_find_by!(
          project_version: project_version,
          collector_type: COLLECTOR_TYPE
        )
      end

      def project_version
        @project_version ||= ProjectVersion.create_or_find_by!(
          project: project,
          commit_sha: synthetic_commit_sha
        ) do |version|
          version.branch = SYNTHETIC_BRANCH
          version.committed_at = session_summary.created_at
        end
      end

      def synthetic_commit_sha
        Digest::SHA1.hexdigest("session-summaries/#{project.id}")[0, 40]
      end

      def project
        session_summary.project
      end
    end
  end
end
