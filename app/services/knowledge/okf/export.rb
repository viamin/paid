# frozen_string_literal: true

module Knowledge
  module Okf
    # Exports selected active knowledge artifacts as an OKF-compatible bundle
    # (Markdown + YAML frontmatter) for diagnostics, portability, review, or
    # bootstrapping a repo-local .okf/ bundle. Paid remains the canonical
    # store; the bundle is a snapshot/interchange artifact, not a sync target.
    #
    # Only artifacts with at least one active (non-redacted, non-stale) chunk
    # are exported — fully redacted artifacts have no active chunks, so the
    # export query excludes them up front rather than fetching them (which
    # would let them consume a `limit`/truncation slot ahead of an
    # exportable artifact that sorts later) or falling back to unscrubbed
    # raw content.
    class Export
      include Rails.application.routes.url_helpers

      # @spec KNOWLEDGE-OKF-005
      # @spec KNOWLEDGE-CURATED-001
      CURATED_ARTIFACT_TYPES = KnowledgeArtifact::CURATED_ARTIFACT_TYPES
      DERIVED_ARTIFACT_TYPES = %w[
        route symbol structure schema churn_hotspot config_key language_stat dependency project_convention
      ].freeze
      EXPORTABLE_ARTIFACT_TYPES = (CURATED_ARTIFACT_TYPES + DERIVED_ARTIFACT_TYPES).freeze

      MAX_ARTIFACTS = 500

      # Aggregate ceiling across all selected types, on top of the per-type
      # MAX_ARTIFACTS. Without this, selecting all exportable types can pull
      # thousands of artifacts (plus their active chunks) into memory in a
      # single synchronous web request.
      MAX_TOTAL_ARTIFACTS = 2000

      # Deliberately not .md: the OkfCollector globs **/*.md when re-ingesting
      # a bundle from .okf/, and this file has no OKF frontmatter to parse.
      TRUNCATION_NOTICE_PATH = "TRUNCATION_NOTICE.txt"

      # Tar entry basenames over 100 bytes raise Gem::Package::TooLongFileName
      # in BundleArchive. Truncating the slug (rather than the whole path)
      # keeps the artifact_type directory prefix and the id suffix intact so
      # paths stay unique.
      MAX_SLUG_LENGTH = 80

      BundleFile = Data.define(:relative_path, :content)
      Result = Data.define(:files, :artifact_types, :exported_count, :skipped_count, :truncated_types)

      def self.call(...) = new(...).call

      def initialize(project:, artifact_types:, max_artifacts: MAX_ARTIFACTS,
        max_total_artifacts: MAX_TOTAL_ARTIFACTS, exported_at: Time.current)
        @project = project
        @artifact_types = normalize_types(artifact_types)
        @max_artifacts = max_artifacts
        @max_total_artifacts = max_total_artifacts
        @exported_at = exported_at
      end

      def call
        raise ArgumentError, "select at least one exportable artifact type" if artifact_types.empty?

        files = []
        skipped = 0
        truncated_types = []
        exported_counts = {}

        artifact_types.each do |type|
          remaining_capacity = max_total_artifacts - files.size
          if remaining_capacity <= 0
            truncated_types << type
            exported_counts[type] = 0
            next
          end

          type_limit = [ max_artifacts, remaining_capacity ].min
          fetched = fetch_artifacts(type, type_limit)
          truncated_types << type if fetched.size > type_limit
          before = files.size
          fetched.first(type_limit).each do |artifact|
            file = build_file(artifact)
            file ? files << file : skipped += 1
          end
          exported_counts[type] = files.size - before
        end

        exported_count = files.size
        files << truncation_notice_file(truncated_types, exported_counts) if truncated_types.any? && files.any?
        Result.new(files: files, artifact_types: artifact_types, exported_count: exported_count,
          skipped_count: skipped, truncated_types: truncated_types)
      end

      private

      attr_reader :project, :artifact_types, :max_artifacts, :max_total_artifacts, :exported_at

      def normalize_types(types)
        Array(types).map(&:to_s).uniq & EXPORTABLE_ARTIFACT_TYPES
      end

      # Fetches one extra row beyond the effective limit so truncation can be
      # detected without a separate COUNT query, then only the first `limit`
      # are used. The per-type max_artifacts is applied (not a global split)
      # so a broad selection can't let one alphabetically-early type starve
      # the rest; the caller further narrows `limit` to the remaining slice
      # of max_total_artifacts so this never over-fetches past the aggregate
      # ceiling.
      def fetch_artifacts(type, limit)
        KnowledgeArtifact
          .for_project(project)
          .active
          .where(artifact_type: type)
          .with_active_chunks
          .includes(:active_ordered_chunks, collector_run: :project_version)
          .order(:identifier, :id)
          .limit(limit + 1)
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
        slug = title_for(artifact).parameterize.truncate(MAX_SLUG_LENGTH, omission: "").presence || artifact.artifact_type
        "#{artifact.artifact_type}/#{slug}-#{artifact.id}.md"
      end

      def truncation_notice_file(truncated_types, exported_counts)
        lines = truncated_types.map { |type| "  - #{type} (#{exported_counts[type]} exported; more matched)" }
        content = <<~NOTICE
          This export was truncated: some selected artifact types had more
          matching knowledge artifacts than the per-type export limit
          (#{max_artifacts}) or the overall export limit
          (#{max_total_artifacts} artifacts) was reached.

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
