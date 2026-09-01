# frozen_string_literal: true

require_relative "base"
require_relative "collector_queries"

module Knowledge
  module Quality
    # Flags active artifacts whose collector run predates the latest indexed
    # project version. The artifact itself is not stale (its collector_run
    # still recorded a successful completion); what's stale is the commit SHA
    # it was indexed against. Operators should re-collect to refresh.
    class Checks::StaleCommitReference < Checks::Base
      include Checks::CollectorQueries

      code "stale_commit_reference"
      severity "info"

      def collect_findings(collector)
        latest = latest_project_version
        return unless latest

        KnowledgeArtifact
          .active
          .for_project(project)
          .joins(:collector_run)
          .includes(collector_run: :project_version)
          .where.not(collector_runs: { project_version_id: latest.id })
          .find_each(batch_size: 200) do |artifact|
            run = artifact.collector_run
            add_finding(
              collector,
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
