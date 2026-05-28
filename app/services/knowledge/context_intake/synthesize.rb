# frozen_string_literal: true

module Knowledge
  module ContextIntake
    # Converts completed intake session responses into KnowledgeArtifact and
    # KnowledgeChunk records so business context is retrievable via
    # Knowledge::Search and includable in context bundles.
    class Synthesize
      ARTIFACT_TYPE = "business_context"
      COLLECTOR_TYPE = "context_intake"

      attr_reader :session

      def initialize(session:)
        @session = session
      end

      def self.call(...)
        new(...).call
      end

      def call
        project = session.project
        cache_invalidation_needed = false
        result = nil

        ActiveRecord::Base.transaction do
          project_version = find_or_create_project_version!(project)
          collector_run = find_or_create_collector_run!(project_version)

          stale_prior_artifacts!(project, collector_run)
          artifacts = create_artifacts!(project, collector_run)

          collector_run.mark_completed!(count: artifacts.size)
          cache_invalidation_needed = true

          result = { collector_run: collector_run, artifacts_count: artifacts.size }
        end
        return result unless cache_invalidation_needed

        ActiveRecord.after_all_transactions_commit do
          KnowledgeArtifact.bust_artifact_counts_cache(project.id) if project&.id
        end

        result
      end

      private

      def find_or_create_project_version!(project)
        latest = project.project_versions.by_recency.first
        return latest if latest

        project.project_versions.create!(
          commit_sha: "0" * 40,
          branch: project.default_branch || "main"
        )
      end

      def find_or_create_collector_run!(project_version)
        existing = project_version.collector_runs.find_by(collector_type: COLLECTOR_TYPE)
        if existing
          existing.mark_running!
          return existing
        end

        project_version.collector_runs.create!(
          collector_type: COLLECTOR_TYPE,
          status: "running",
          started_at: Time.current
        )
      end

      def stale_prior_artifacts!(project, _current_run)
        KnowledgeArtifact
          .for_project(project)
          .active
          .by_type(ARTIFACT_TYPE)
          .update_all(status: "stale")
      end

      def create_artifacts!(project, collector_run)
        responses_by_section = QuestionnaireSchema.ordered_responses(
          session.context_intake_responses.where(skipped: false).where.not(answer_text: [ nil, "" ]).to_a
        ).group_by(&:section)

        responses_by_section.map do |section_key, responses|
          create_section_artifact!(project, collector_run, section_key, responses)
        end
      end

      def create_section_artifact!(project, collector_run, section_key, responses)
        section_title = QuestionnaireSchema.question_for_response(responses.first)[:section_title]

        content = responses.map { |r| "**#{r.question_text}**\n#{r.answer_text}" }.join("\n\n")
        content_hash = Digest::SHA256.hexdigest(content)

        artifact = KnowledgeArtifact.create!(
          project: project,
          collector_run: collector_run,
          artifact_type: ARTIFACT_TYPE,
          collector_type: COLLECTOR_TYPE,
          scope_path: "business_context/#{section_key}",
          identifier: "business_context:#{section_key}",
          content: content,
          content_hash: content_hash,
          metadata: {
            section_key: section_key,
            section_title: section_title,
            session_id: session.id,
            response_count: responses.size,
            provenances: responses.map(&:provenance).uniq
          },
          status: "active"
        )

        responses.each_with_index do |response, idx|
          artifact.knowledge_chunks.create!(
            project: project,
            chunk_type: "context",
            content: "#{section_title}: #{response.question_text}\n#{response.answer_text}",
            content_hash: Digest::SHA256.hexdigest("#{response.question_key}:#{response.answer_text}"),
            scope_tags: [ section_key, "business_context" ],
            sequence: idx,
            status: "active"
          )
        end

        log_audit_event!(project, artifact, collector_run)

        artifact
      end

      def log_audit_event!(project, artifact, collector_run)
        Knowledge::Provenance::AuditLog.record(
          event: :artifact_created,
          project: project,
          actor: { type: "context_intake", id: collector_run.id.to_s },
          target: { type: "KnowledgeArtifact", id: artifact.id.to_s },
          details: { artifact_type: ARTIFACT_TYPE, identifier: artifact.identifier }
        )
      end
    end
  end
end
