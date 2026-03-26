# frozen_string_literal: true

require "csv"
require "shellwords"

module Knowledge
  module Collectors
    class ChurnHotspotCollector < BaseCollector
      MAAT_TIMEOUT = 120 # seconds

      def collect
        repo_path = resolve_repo_path
        return [] unless repo_path

        revisions = run_maat(repo_path, "revisions")
        hotspots = run_maat(repo_path, "hotspots")

        return [] if revisions.empty? && hotspots.empty?

        build_artifacts(revisions, hotspots)
      end

      def collector_type
        "churn_hotspot"
      end

      def tool_version
        version_output = run_command("maat --version")
        version_output.strip.presence
      rescue StandardError
        nil
      end

      private

      def run_maat(repo_path, analysis)
        output = run_command(
          "maat -c git2 -l #{Shellwords.escape(repo_path)} -a #{analysis}",
          timeout: MAAT_TIMEOUT
        )
        parse_csv(output)
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.churn_hotspot_collector.maat_failed",
          analysis: analysis,
          project_id: project.id,
          error: e.message
        )
        []
      end

      def parse_csv(output)
        return [] if output.blank?

        rows = CSV.parse(output, headers: true)
        rows.map(&:to_h)
      rescue CSV::MalformedCSVError
        []
      end

      def build_artifacts(revisions, hotspots)
        revision_map = build_revision_map(revisions)
        hotspot_map = build_hotspot_map(hotspots)

        all_files = (revision_map.keys + hotspot_map.keys).uniq
        ranked = rank_files(all_files, revision_map, hotspot_map)

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

      def build_hotspot_map(hotspots)
        hotspots.each_with_object({}) do |row, map|
          entity = row["entity"] || row["module"]
          next unless entity

          map[entity] = (row["code"] || row["complexity"] || "0").to_i
        end
      end

      def rank_files(files, revision_map, hotspot_map)
        files.map do |file|
          revs = revision_map.fetch(file, 0)
          complexity = hotspot_map.fetch(file, 0)
          { file: file, revisions: revs, complexity: complexity, score: revs * complexity }
        end.sort_by { |e| -e[:score] }
      end

      def build_artifact(entry, rank)
        file = entry[:file]
        revisions = entry[:revisions]
        complexity = entry[:complexity]

        {
          artifact_type: "churn_hotspot",
          scope_path: file,
          identifier: file,
          content: "Churn hotspot: #{file} — #{revisions} revisions, complexity score #{complexity}",
          metadata: { revisions: revisions, complexity: complexity, rank: rank },
          chunks: [
            {
              chunk_type: "summary",
              content: build_chunk_text(file, revisions, complexity, rank),
              scope_tags: [ "churn", "hotspot" ]
            }
          ]
        }
      end

      def build_chunk_text(file, revisions, complexity, rank)
        traits = []
        traits << "#{revisions} revisions" if revisions > 0
        traits << "complexity #{complexity}" if complexity > 0

        if traits.any?
          "#{file} is a high-churn file (#{traits.join(', ')}, rank ##{rank}). " \
            "Changes here need careful review."
        else
          "#{file} (rank ##{rank}): no significant churn or complexity detected."
        end
      end
    end
  end
end
