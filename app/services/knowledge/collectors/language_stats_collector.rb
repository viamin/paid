# frozen_string_literal: true

require "json"

module Knowledge
  module Collectors
    class LanguageStatsCollector < BaseCollector
      SCC_TIMEOUT = 60 # seconds

      def collect
        repo_path = resolve_repo_path
        return [] unless repo_path

        languages = run_scc(repo_path)
        return [] if languages.empty?

        languages.map { |lang| build_artifact(lang) }
      end

      def collector_type
        "language_stat"
      end

      def tool_version
        output = run_command("scc", "--version")
        output.strip.presence
      rescue StandardError
        nil
      end

      private

      def run_scc(repo_path)
        output = run_command(
          "scc", "--format", "json", repo_path,
          timeout: SCC_TIMEOUT
        )
        parse_scc_json(output)
      rescue StandardError => e
        Rails.logger.warn(
          message: "knowledge.language_stats_collector.scc_failed",
          project_id: project.id,
          error: e.message
        )
        []
      end

      def parse_scc_json(output)
        return [] if output.blank?

        data = JSON.parse(output)
        return [] unless data.is_a?(Array)

        data.filter_map do |entry|
          name = entry["Name"]
          next unless name

          {
            name: name,
            files: entry["Count"] || 0,
            lines: entry["Lines"] || 0,
            code: entry["Code"] || 0,
            comments: entry["Comment"] || 0,
            blanks: entry["Blank"] || 0
          }
        end
      end

      def build_artifact(lang)
        {
          artifact_type: "language_stat",
          scope_path: nil,
          identifier: lang[:name],
          content: "#{lang[:name]}: #{number_with_delimiter(lang[:code])} lines of code, " \
                   "#{number_with_delimiter(lang[:comments])} comments, " \
                   "#{number_with_delimiter(lang[:blanks])} blanks, " \
                   "#{number_with_delimiter(lang[:lines])} total lines across #{lang[:files]} files",
          metadata: {
            files: lang[:files],
            lines: lang[:lines],
            code: lang[:code],
            comments: lang[:comments],
            blanks: lang[:blanks]
          },
          chunks: [
            {
              chunk_type: "summary",
              content: "The project contains #{lang[:name]} code: " \
                       "#{number_with_delimiter(lang[:code])} lines of code, " \
                       "#{number_with_delimiter(lang[:comments])} comments, " \
                       "across #{lang[:files]} files.",
              scope_tags: [ "language", "stats" ]
            }
          ]
        }
      end

      def number_with_delimiter(number)
        number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      end
    end
  end
end
