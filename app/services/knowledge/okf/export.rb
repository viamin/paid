# frozen_string_literal: true

module Knowledge
  module Okf
    # Exports selected active knowledge artifacts as an OKF-compatible bundle
    # (Markdown + YAML frontmatter) for diagnostics, portability, review, or
    # bootstrapping a repo-local .okf/ bundle. Paid remains the canonical
    # store; the bundle is a snapshot/interchange artifact, not a sync target.
    #
    # Only artifacts with at least one active (non-redacted, non-stale) chunk
    # are exported — fully redacted artifacts have no active chunks and are
    # skipped rather than falling back to unscrubbed raw content.
    class Export
      include Rails.application.routes.url_helpers

      # @spec KNOWLEDGE-OKF-005
      CURATED_ARTIFACT_TYPES = %w[
        okf_concept business_context reference_document decision_record change_intent
      ].freeze
      DERIVED_ARTIFACT_TYPES = %w[
        route symbol structure schema churn_hotspot config_key language_stat dependency project_convention
      ].freeze
      EXPORTABLE_ARTIFACT_TYPES = (CURATED_ARTIFACT_TYPES + DERIVED_ARTIFACT_TYPES).freeze

      MAX_ARTIFACTS = 500

      # Deliberately not .md: the OkfCollector globs **/*.md when re-ingesting
      # a bundle from .okf/, and this file has no OKF frontmatter to parse.
      TRUNCATION_NOTICE_PATH = "TRUNCATION_NOTICE.txt"

      BundleFile = Data.define(:relative_path, :content)
      Result = Data.define(:files, :artifact_types, :skipped_count, :truncated_types)

      def self.call(...) = new(...).call

      def initialize(project:, artifact_types:, actor: nil, max_artifacts: MAX_ARTIFACTS, exported_at: Time.current)
        @project = project
        @artifact_types = normalize_types(artifact_types)
        @actor = actor
        @max_artifacts = max_artifacts
        @exported_at = exported_at
      end

      def call
        raise ArgumentError, "select at least one exportable artifact type" if artifact_types.empty?

        files = []
        skipped = 0
        truncated_types = []

        artifact_types.each do |type|
          fetched = fetch_artifacts(type)
          truncated_types << type if fetched.size > max_artifacts
          fetched.first(max_artifacts).each do |artifact|
            file = build_file(artifact)
            file ? files << file : skipped += 1
          end
        end

        record_audit_event(files.size, skipped, truncated_types)
        files << truncation_notice_file(truncated_types) if truncated_types.any? && files.any?
        Result.new(files: files, artifact_types: artifact_types, skipped_count: skipped, truncated_types: truncated_types)
      end

      private

      attr_reader :project, :artifact_types, :actor, :max_artifacts, :exported_at

      def normalize_types(types)
        Array(types).map(&:to_s).uniq & EXPORTABLE_ARTIFACT_TYPES
      end

      # Fetches one extra row beyond max_artifacts so truncation can be
      # detected without a separate COUNT query, then only the first
      # max_artifacts are used. Applied per type (not globally) so a broad
      # selection can't let one alphabetically-early type starve the rest.
      def fetch_artifacts(type)
        KnowledgeArtifact
          .for_project(project)
          .active
          .where(artifact_type: type)
          .includes(:active_ordered_chunks, collector_run: :project_version)
          .order(:identifier, :id)
          .limit(max_artifacts + 1)
          .to_a
      end

      # Renders and immediately re-parses the file so an artifact only ever
      # ships in the bundle if it validates against the shape the collector
      # expects to read back.
      def build_file(artifact)
        body = body_for(artifact)
        return nil if body.blank?

        rendered = Frontmatter.render(frontmatter: frontmatter_for(artifact), body: body)
        return nil unless Frontmatter.parse(rendered).valid?

        BundleFile.new(relative_path: relative_path_for(artifact), content: rendered)
      end

      def body_for(artifact)
        chunks = artifact.active_ordered_chunks.to_a
        return nil if chunks.empty?

        definition = chunks.find { |chunk| chunk.chunk_type == "definition" }
        (definition&.content || chunks.map(&:content).join("\n\n")).strip
      end

      def frontmatter_for(artifact)
        {
          "title" => title_for(artifact),
          "type" => artifact.metadata&.dig("concept_type") || artifact.artifact_type,
          "tags" => Array(artifact.metadata&.dig("tags")),
          "paid" => paid_metadata(artifact)
        }
      end

      def title_for(artifact)
        artifact.metadata&.dig("title").presence || artifact.identifier.presence ||
          artifact.scope_path.presence || "#{artifact.artifact_type} #{artifact.id}"
      end

      def paid_metadata(artifact)
        {
          "kb_uri" => kb_uri_for(artifact),
          "artifact_type" => artifact.artifact_type,
          "collector_type" => artifact.collector_type,
          "scope" => artifact.scope_path,
          "identifier" => artifact.identifier,
          "commit_sha" => commit_sha_for(artifact),
          "created_at" => artifact.created_at.utc.iso8601,
          "updated_at" => artifact.updated_at.utc.iso8601,
          "exported_at" => exported_at.utc.iso8601
        }.compact
      end

      def commit_sha_for(artifact)
        artifact.collector_run&.project_version&.commit_sha
      end

      def kb_uri_for(artifact)
        knowledge_artifact_url(artifact, **url_host_options)
      rescue ArgumentError
        knowledge_artifact_path(artifact)
      end

      def url_host_options
        ActionMailer::Base.default_url_options.slice(:host, :port)
      end

      def relative_path_for(artifact)
        slug = title_for(artifact).parameterize.presence || artifact.artifact_type
        "#{artifact.artifact_type}/#{slug}-#{artifact.id}.md"
      end

      def record_audit_event(exported_count, skipped_count, truncated_types)
        Knowledge::Provenance::AuditLog.record(
          event: :okf_bundle_exported,
          project: project,
          actor: actor || { type: "system" },
          details: {
            artifact_types: artifact_types,
            exported_count: exported_count,
            skipped_count: skipped_count,
            truncated_types: truncated_types
          }
        )
      end

      def truncation_notice_file(truncated_types)
        lines = truncated_types.map { |type| "  - #{type} (more than #{max_artifacts} matching, only #{max_artifacts} exported)" }
        content = <<~NOTICE
          This export was truncated: some selected artifact types had more
          matching knowledge artifacts than the per-type export limit.

          Truncated types:
          #{lines.join("\n")}

          This bundle is incomplete for those types. To get a complete export,
          narrow the artifact type selection and export the remaining types
          separately.
        NOTICE

        BundleFile.new(relative_path: TRUNCATION_NOTICE_PATH, content: content)
      end
    end
  end
end
