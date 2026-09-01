# frozen_string_literal: true

module Knowledge
  module Collectors
    # Indexes repo-local OKF bundles (Markdown + YAML frontmatter) as curated
    # knowledge artifacts, separate from derived collector output. Skips
    # cleanly for repositories without a bundle.
    class OkfCollector < BaseCollector
      # @spec KNOWLEDGE-OKF-001
      # @spec KNOWLEDGE-OKF-002
      # @spec KNOWLEDGE-OKF-004
      DEFAULT_ROOTS = [ ".okf" ].freeze
      DEFAULT_CONCEPT_TYPE = "concept"
      MAX_FILE_BYTES = 1.megabyte
      GIT_LOG_FORMAT = "%H%x1f%aN%x1f%aI%x1f%s"

      def collect
        roots = detect_bundle_roots
        skip!("no OKF bundle found") if roots.empty?

        findings = []
        artifacts = concept_files(roots).filter_map do |absolute_path, relative_path, root_relative_path|
          concept, finding = parse_concept(absolute_path, relative_path, root_relative_path)
          findings << finding if finding
          concept && build_artifact(concept)
        end
        record_findings(findings)
        artifacts
      end

      def collector_type
        "okf"
      end

      def tool_version
        "1.0.0"
      end

      private

      def detect_bundle_roots
        base = host_repo_path
        skip!("repository path not available") if base.blank?

        @repo_base = File.expand_path(base)
        repo_realpath = File.realpath(@repo_base)
        (configured_roots + DEFAULT_ROOTS)
          .filter_map { |relative| bundle_root(relative, repo_realpath) }
          .uniq { |root| root[:relative] }
      rescue Errno::ENOENT, Errno::EACCES
        skip!("repository path is not accessible")
        []
      end

      def configured_roots
        Array(options[:okf_paths]).filter_map { |path| path.to_s.strip.presence }
      end

      # Resolve `relative` against the repo base and confirm it still lives
      # inside the repository *after* symlinks are followed. Without the
      # realpath check, an `.okf` symlink pointing to `/etc` would pass the
      # lexical start_with? guard and let `Dir.glob` index arbitrary files.
      def bundle_root(relative, repo_realpath)
        absolute = File.expand_path(relative, @repo_base)
        return nil unless absolute.start_with?("#{@repo_base}/")

        resolved = File.realpath(absolute)
        return nil unless resolved.start_with?("#{repo_realpath}/")
        return nil unless File.directory?(resolved)

        { absolute: resolved, relative: resolved.delete_prefix("#{repo_realpath}/") }
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def concept_files(roots)
        roots.flat_map do |root|
          Dir.glob(File.join(root[:absolute], "**", "*.md")).sort.map do |path|
            root_relative = path.delete_prefix("#{root[:absolute]}/")
            relative_path = "#{root[:relative]}/#{root_relative}"
            [ path, relative_path, root_relative ]
          end
        end.uniq
      end

      # Returns [concept, nil] for a valid concept file or [nil, finding] for
      # an invalid one. Invalid files never raise: they become findings so the
      # collector run completes and other collectors are unaffected.
      def parse_concept(absolute_path, relative_path, root_relative_path)
        raw = File.read(absolute_path)
        return invalid(relative_path, "file exceeds #{MAX_FILE_BYTES} bytes") if raw.bytesize > MAX_FILE_BYTES

        result = Okf::Frontmatter.parse(raw)
        return invalid(relative_path, result.error) unless result.valid?

        [ concept_for(result.frontmatter, result.body, relative_path, root_relative_path), nil ]
      rescue Errno::ENOENT, Errno::EACCES => e
        invalid(relative_path, "unreadable file: #{e.message}")
      end

      def invalid(relative_path, reason)
        [ nil, error_finding(relative_path, reason) ]
      end

      def concept_for(frontmatter, body, relative_path, root_relative_path)
        {
          relative_path: relative_path,
          title: title_for(frontmatter, relative_path),
          concept_type: concept_type_for(frontmatter, root_relative_path),
          tags: normalize_tags(frontmatter["tags"]),
          body: body.strip,
          last_commit: last_commit_for(relative_path)
        }
      end

      def title_for(frontmatter, relative_path)
        title = frontmatter["title"].to_s.strip.presence || File.basename(relative_path, ".md")
        title.truncate(500)
      end

      def concept_type_for(frontmatter, relative_path)
        explicit = frontmatter["type"].to_s.strip
        return explicit if explicit.present?

        segment = File.dirname(relative_path).split(File::SEPARATOR).first
        segment == "." ? DEFAULT_CONCEPT_TYPE : segment
      end

      def normalize_tags(value)
        tags = value.is_a?(Array) ? value.map(&:to_s) : value.is_a?(String) ? value.split(",") : []
        tags.filter_map { |tag| tag.strip.presence }.uniq
      end

      def last_commit_for(relative_path)
        output = run_command(
          "git", "-C", resolve_repo_path, "log", "-n", "1",
          "--format=#{GIT_LOG_FORMAT}", "--", relative_path,
          timeout: 15
        )
        return nil if output.blank?

        sha, author, date, subject = output.strip.split("\x1f", 4)
        { "sha" => sha, "author" => author, "date" => date, "subject" => subject }
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.okf_collector.git_log_failed",
          project_id: project.id,
          path: relative_path,
          error: e.message
        )
        nil
      end

      def build_artifact(concept)
        {
          artifact_type: "okf_concept",
          scope_path: concept[:relative_path],
          identifier: concept[:title],
          content: concept[:body],
          metadata: artifact_metadata(concept),
          chunks: [
            {
              chunk_type: "summary",
              content: summary_line(concept),
              scope_tags: scope_tags(concept),
              sequence: 0
            },
            {
              chunk_type: "definition",
              content: concept[:body],
              scope_tags: scope_tags(concept),
              sequence: 1
            }
          ]
        }
      end

      def artifact_metadata(concept)
        metadata = {
          "source_path" => concept[:relative_path],
          "concept_type" => concept[:concept_type],
          "title" => concept[:title],
          "tags" => concept[:tags]
        }
        metadata["last_commit"] = concept[:last_commit] if concept[:last_commit]
        metadata
      end

      def summary_line(concept)
        parts = [ "#{concept[:title]} (#{concept[:concept_type]})" ]
        parts << "tags: #{concept[:tags].join(', ')}" if concept[:tags].any?
        parts.join(" — ")
      end

      def scope_tags(concept)
        [ "okf", concept[:concept_type] ]
      end

      def error_finding(relative_path, reason)
        { "severity" => "error", "path" => relative_path, "reason" => reason }
      end

      def record_findings(findings)
        return if findings.empty?

        collector_run.update!(metadata: collector_run.metadata.merge("findings" => findings))
        Rails.logger.warn(
          message: "knowledge.okf_collector.invalid_files",
          project_id: project.id,
          count: findings.length
        )
      end
    end
  end
end
