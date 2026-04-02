# frozen_string_literal: true

require "csv"
require "json"
require "tempfile"

module Knowledge
  module Collectors
    class ChurnHotspotCollector < BaseCollector
      MAAT_TIMEOUT = 120 # seconds
      GIT_LOG_FORMAT = "--%h--%ad--%aN"

      def collect
        repo_path = resolve_repo_path
        return [] unless repo_path

        revisions = run_revisions(repo_path)
        complexity = run_complexity(repo_path)

        return [] if revisions.empty? && complexity.empty?

        build_artifacts(revisions, complexity)
      end

      def collector_type
        "churn_hotspot"
      end

      def tool_version
        version_output = run_command("ruby-maat", "--version")
        version_output.strip.presence
      rescue StandardError
        nil
      end

      private

      def run_revisions(repo_path)
        Tempfile.create([ "maat_log", ".log" ]) do |f|
          stream_git_log(repo_path, f)
          return [] if f.size.zero?

          output = run_command(
            "ruby-maat", "-c", "git2", "-l", f.path, "-a", "revisions", "-n", "1",
            timeout: MAAT_TIMEOUT
          )
          parse_csv(output)
        end
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.churn_hotspot_collector.revisions_failed",
          project_id: project.id,
          error: e.message
        )
        []
      end

      def run_complexity(repo_path)
        output = run_command(
          "scc", "--by-file", "-f", "json", repo_path,
          timeout: MAAT_TIMEOUT
        )
        parse_scc_complexity(output, repo_path)
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.churn_hotspot_collector.complexity_failed",
          project_id: project.id,
          error: e.message
        )
        []
      end

      # Streams git log output directly to the given file to avoid loading
      # the entire log into a Ruby string (can be very large for big repos).
      def stream_git_log(repo_path, output_file)
        args = [
          "git", "-C", repo_path, "log", "--all", "--numstat",
          "--date=short", "--pretty=format:#{GIT_LOG_FORMAT}", "--no-renames"
        ]

        Timeout.timeout(MAAT_TIMEOUT) do
          Open3.popen3(*args, pgroup: true) do |stdin, stdout, _stderr, wait_thr|
            stdin.close
            output_file.write(stdout.read)
            output_file.flush
            raise "git log failed (exit #{wait_thr.value.exitstatus})" unless wait_thr.value.success?
          end
        end
      end

      def parse_csv(output)
        return [] if output.blank?

        rows = CSV.parse(output, headers: true)
        rows.map(&:to_h)
      rescue CSV::MalformedCSVError => e
        Rails.logger.warn(
          message: "knowledge.churn_hotspot_collector.malformed_csv",
          project_id: project.id,
          error: e.message,
          output_snippet: output.to_s.first(200)
        )
        []
      end

      def parse_scc_complexity(output, repo_path)
        return [] if output.blank?

        data = JSON.parse(output)
        return [] unless data.is_a?(Array)

        prefix = repo_path.end_with?("/") ? repo_path : "#{repo_path}/"

        data.flat_map do |language_entry|
          (language_entry["Files"] || []).filter_map do |file_entry|
            location = file_entry["Location"]
            next unless location&.start_with?(prefix)

            entity = location.delete_prefix(prefix)
            complexity = file_entry["Complexity"] || 0
            next if complexity <= 0

            { "entity" => entity, "complexity" => complexity.to_s }
          end
        end
      rescue JSON::ParserError => e
        Rails.logger.warn(
          message: "knowledge.churn_hotspot_collector.malformed_scc_json",
          project_id: project.id,
          error: e.message,
          output_snippet: output.to_s.first(200)
        )
        []
      end

      def build_artifacts(revisions, complexity_data)
        revision_map = build_revision_map(revisions)
        complexity_map = build_complexity_map(complexity_data)

        all_files = (revision_map.keys + complexity_map.keys).uniq
        ranked = rank_files(all_files, revision_map, complexity_map)

        ranked.each_with_index.map do |entry, index|
          rank = index + 1
          build_artifact(entry, rank)
        end
      end

      def build_revision_map(revisions)
        revisions.each_with_object({}) do |row, map|
          entity = row["entity"]
          next unless entity

          map[entity] = (row["n-revs"] || row["revisions"] || "0").to_i
        end
      end

      def build_complexity_map(complexity_data)
        complexity_data.each_with_object({}) do |row, map|
          entity = row["entity"] || row["module"]
          next unless entity

          map[entity] = (row["code"] || row["complexity"] || "0").to_i
        end
      end

      def rank_files(files, revision_map, complexity_map)
        files.map do |file|
          revs = revision_map.fetch(file, 0)
          complexity = complexity_map.fetch(file, 0)
          { file: file, revisions: revs, complexity: complexity, score: revs * complexity }
        end.sort_by { |e| [ -e[:score], -e[:revisions], -e[:complexity], e[:file] ] }
      end

      def build_artifact(entry, rank)
        file = entry[:file]
        revisions = entry[:revisions]
        complexity = entry[:complexity]

        {
          artifact_type: "churn_hotspot",
          scope_path: file,
          identifier: file,
          content: build_content(file, revisions, complexity),
          metadata: { revisions: revisions, complexity: complexity, rank: rank },
          chunks: [
            {
              chunk_type: "summary",
              sequence: 0,
              content: build_chunk_text(file, revisions, complexity, rank),
              scope_tags: [ "churn", "hotspot" ]
            }
          ]
        }
      end

      def build_content(file, revisions, complexity)
        traits = []
        traits << "#{revisions} revisions" if revisions > 0
        traits << "complexity score #{complexity}" if complexity > 0

        if traits.empty?
          "Churn hotspot: #{file} — no significant churn or complexity detected."
        else
          "Churn hotspot: #{file} — #{traits.join(', ')}"
        end
      end

      def build_chunk_text(file, revisions, complexity, rank)
        traits = []
        traits << "#{revisions} revisions" if revisions > 0
        traits << "complexity #{complexity}" if complexity > 0

        if revisions > 0 && complexity > 0
          "#{file} has high churn and complexity (#{traits.join(', ')}, rank ##{rank}). " \
            "Changes here need careful review."
        elsif revisions > 0
          "#{file} is a high-churn file (#{traits.join(', ')}, rank ##{rank}). " \
            "Changes here need careful review."
        elsif complexity > 0
          "#{file} is a complexity hotspot (#{traits.join(', ')}, rank ##{rank}). " \
            "Changes here need careful review."
        else
          "#{file} (rank ##{rank}): no significant churn or complexity detected."
        end
      end
    end
  end
end
