# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Flags active artifacts whose collector run predates the latest indexed
    # project version. The artifact itself is not stale (its collector_run
    # still recorded a successful completion); what's stale is the commit SHA
    # it was indexed against. Operators should re-collect to refresh.
    class Checks::StaleCommitReference < Checks::Base
      code "stale_commit_reference"
      severity "info"

      def findings
        latest = latest_project_version
        return [] unless latest

        results = []
        KnowledgeArtifact
          .active
          .for_project(project)
          .joins(:collector_run)
          .includes(collector_run: :project_version)
          .where.not(collector_runs: { project_version_id: latest.id })
          .find_each(batch_size: 200) do |artifact|
            run = artifact.collector_run
            results << build_finding(
              target_type: "KnowledgeArtifact",
              target_id: artifact.id,
              artifact_type: artifact.artifact_type,
              detail: "collector indexed at #{run&.project_version&.commit_sha&.first(7)}, " \
                      "HEAD is #{latest.commit_sha&.first(7)}"
            )
          end

        results
      end

      private

      def latest_project_version
        @latest_project_version ||= project.project_versions
          .where.not(committed_at: nil)
          .order(committed_at: :desc)
          .first
      end
    end
  end
end
