# frozen_string_literal: true

require_relative "base"
require_relative "collector_queries"

module Knowledge
  module Quality
    # Flags active artifacts whose collector run predates the latest indexed
    # project version. The artifact itself is not stale (its collector_run
    # still recorded a successful completion); what's stale is the commit SHA
    # it was indexed against. Operators should re-collect to refresh.
    #
    # Artifacts whose collector runs belong to a synthetic project version
    # (Knowledge::SessionSummaries::SyncKnowledgeArtifact,
    # ChangeIntents::SyncKnowledgeArtifact) are excluded: their runs can
    # never match the latest real version, and any "re-collect" operator
    # action would just produce a fresh synthetic version alongside the
    # existing one — these artifacts are DB-derived, not git-derived, so the
    # notion of "stale against HEAD" doesn't apply.
    class Checks::StaleCommitReference < Checks::Base
      include Checks::CollectorQueries

      code "stale_commit_reference"
      severity "info"

      def collect_findings(collector)
        latest = latest_project_version
        return unless latest

        scope = KnowledgeArtifact
          .active
          .for_project(project)
          .joins(collector_run: :project_version)
          .where.not(collector_runs: { project_version_id: latest.id })
          .where.not(project_versions: { branch: SYNTHETIC_BRANCHES })

        collect_scope(collector, scope.preload(collector_run: :project_version)) do |artifact|
          run = artifact.collector_run
          build_finding(
            target_type: "KnowledgeArtifact",
            target_id: artifact.id,
            artifact_type: artifact.artifact_type,
            detail: "collector indexed at #{run&.project_version&.commit_sha&.first(7)}, " \
                    "HEAD is #{latest.commit_sha&.first(7)}"
          )
        end
      end
    end
  end
end
