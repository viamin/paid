# frozen_string_literal: true

module Knowledge
  module Map
    # Builds a compact, bounded overview of what Paid knows about a project:
    # artifact counts by type, top scopes, collector freshness, curated
    # knowledge presence (business context, imported documents), and inferred
    # gaps. Agents fetch this before running search to orient without loading
    # chunk bodies.
    #
    # @example
    #   Knowledge::Map::Build.call(project: project)
    class Build
      # @spec KNOWLEDGE-009
      TOP_SCOPES_LIMIT = 15
      IMPORTED_DOCUMENTS_LIMIT = 10
      BUSINESS_CONTEXT_COLLECTOR_TYPE = "context_intake"

      attr_reader :project

      def initialize(project:)
        @project = project
      end

      def self.call(...)
        new(...).call
      end

      def call
        {
          project_id: project.id,
          generated_at: Time.current.iso8601,
          latest_commit: latest_commit_info,
          artifact_counts: artifact_counts,
          top_scopes: top_scopes,
          collectors: collector_freshness,
          business_context: business_context_summary,
          imported_documents: imported_documents_summary,
          gaps: gaps
        }
      end

      private

      def latest_commit_info
        version = latest_project_version
        return nil unless version

        { commit_sha: version.commit_sha, branch: version.branch, committed_at: version.committed_at&.iso8601 }
      end

      def latest_project_version
        @latest_project_version ||= project.project_versions
          .where.not(committed_at: nil)
          .order(committed_at: :desc)
          .first
      end

      def artifact_counts
        counts = KnowledgeArtifact.for_project(project)
          .where(status: %w[active stale])
          .group(:artifact_type, :status)
          .count

        counts.each_with_object(Hash.new { |h, k| h[k] = { active: 0, stale: 0 } }) do |((type, status), count), acc|
          acc[type][status.to_sym] = count
        end
      end

      def top_scopes
        scope_counts = KnowledgeArtifact.active.for_project(project)
          .where.not(scope_path: nil)
          .where.not(scope_path: "")
          .group(Arel.sql("split_part(scope_path, '/', 1)"))
          .count

        scope_counts.sort_by { |_, count| -count }.first(TOP_SCOPES_LIMIT)
          .map { |scope, count| { scope: scope, artifact_count: count } }
      end

      def collector_freshness
        registered_types = Knowledge::CollectorRunner.registry.keys
        observed_types = (registered_types + latest_collector_runs_by_type.keys).uniq

        observed_types.map { |type| collector_status(type) }
      end

      def collector_status(type)
        run = latest_collector_runs_by_type[type]
        {
          collector_type: type,
          status: run&.status || "never_run",
          last_completed_at: run&.completed_at&.iso8601,
          artifacts_count: run&.artifacts_count,
          project_version_commit_sha: run&.project_version&.commit_sha
        }
      end

      def gaps
        Knowledge::CollectorRunner.registry.keys.filter_map do |type|
          classify_gap(type, latest_collector_runs_by_type[type])
        end
      end

      def classify_gap(type, run)
        return { collector_type: type, reason: "never_run" } if run.nil?
        return { collector_type: type, reason: "failed", detail: run.error_message } if run.status == "failed"
        return { collector_type: type, reason: "stale", detail: "last collected at #{run.project_version&.commit_sha}" } if stale_run?(run)

        nil
      end

      def stale_run?(run)
        return false unless run.status == "completed"
        return false unless latest_project_version&.committed_at && run.project_version&.committed_at

        run.project_version.committed_at < latest_project_version.committed_at
      end

      # DISTINCT ON picks each collector type's most recent run in one query;
      # project_version is attached manually from a second batched query so
      # accessing it below never triggers a per-run N+1.
      def latest_collector_runs_by_type
        @latest_collector_runs_by_type ||= begin
          runs = CollectorRun
            .joins(:project_version)
            .where(project_versions: { project_id: project.id })
            .select("DISTINCT ON (collector_runs.collector_type) collector_runs.*")
            .order(:collector_type, created_at: :desc)
            .to_a
          attach_project_versions(runs)
          runs.index_by(&:collector_type)
        end
      end

      def attach_project_versions(runs)
        versions = ProjectVersion.where(id: runs.map(&:project_version_id)).index_by(&:id)
        runs.each { |run| run.association(:project_version).target = versions[run.project_version_id] }
      end

      def business_context_summary
        artifacts = KnowledgeArtifact.active.for_project(project).by_type("business_context")
        last_run = latest_collector_runs_by_type[BUSINESS_CONTEXT_COLLECTOR_TYPE]

        {
          present: artifacts.exists?,
          artifact_count: artifacts.count,
          last_synthesized_at: last_run&.completed_at&.iso8601
        }
      end

      def imported_documents_summary
        scope = KnowledgeArtifact.active.for_project(project).by_type("reference_document")
        items = scope.order(created_at: :desc).limit(IMPORTED_DOCUMENTS_LIMIT).map do |artifact|
          { identifier: artifact.identifier, title: artifact.metadata&.dig("title"), imported_at: artifact.created_at.iso8601 }
        end

        { count: scope.count, items: items }
      end
    end
  end
end
