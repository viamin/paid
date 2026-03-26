# frozen_string_literal: true

module Knowledge
  module Collectors
    class DependencyCollector < BaseCollector
      MANIFEST_PARSERS = {
        "Gemfile" => :parse_gemfile,
        "package.json" => :parse_package_json,
        "requirements.txt" => :parse_requirements_txt,
        "go.mod" => :parse_go_mod
      }.freeze

      def collect
        artifacts = []

        MANIFEST_PARSERS.each do |filename, parser_method|
          file_path = File.join(scan_path, filename)
          next unless File.exist?(file_path)

          content = File.read(file_path)
          deps = send(parser_method, content)

          deps.each do |dep|
            version_str = dep[:version] ? " #{dep[:version]}" : ""
            identifier = "#{dep[:name]}#{version_str}"

            artifacts << {
              artifact_type: "dependency",
              scope_path: filename,
              identifier: identifier,
              content: dep[:raw_line] || identifier,
              metadata: {
                name: dep[:name],
                version: dep[:version],
                source: dep[:source] || filename,
                group: dep[:group] || "default"
              },
              chunks: [
                {
                  chunk_type: "definition",
                  content: dep[:raw_line] || identifier,
                  scope_tags: [ filename ],
                  sequence: 0
                }
              ]
            }
          end
        end

        artifacts
      end

      def collector_type
        "dependency"
      end

      private

      def parse_gemfile(content)
        deps = []
        current_group = "default"
        group_nesting = 0

        content.each_line do |line|
          stripped = line.strip

          if (group_match = stripped.match(/\Agroup\s*(?:\(\s*(.+?)\s*\)|(\s.+?))\s+do\z/))
            group_names = group_match[1] || group_match[2]
            current_group = group_names.gsub(/[:\s,]/, " ").split.join(", ")
            group_nesting = 1
            next
          end

          if group_nesting.positive?
            group_nesting += 1 if stripped.match?(/\bdo\z/)

            if stripped == "end"
              group_nesting -= 1
              current_group = "default" if group_nesting.zero?
              next
            end
          end

          if (gem_match = stripped.match(/\Agem\s+["']([^"']+)["']((?:,\s*["'][^"']+["'])*)/))
            versions = gem_match[2].scan(/["']([^"']+)["']/).flatten
            version = versions.empty? ? nil : versions.join(", ")

            deps << {
              name: gem_match[1],
              version: version,
              group: current_group,
              source: "Gemfile",
              raw_line: stripped
            }
          end
        end

        deps
      end

      def parse_package_json(content)
        data = JSON.parse(content)
        deps = []

        %w[dependencies devDependencies peerDependencies].each do |section|
          group = section_to_group(section)
          (data[section] || {}).each do |name, version|
            deps << {
              name: name,
              version: version,
              group: group,
              source: "package.json",
              raw_line: "\"#{name}\": \"#{version}\""
            }
          end
        end

        deps
      rescue JSON::ParserError => e
        Rails.logger.warn(
          message: "knowledge.dependency.package_json_parse_error",
          scan_path: scan_path,
          error: e.message
        )
        []
      end

      def parse_requirements_txt(content)
        deps = []

        content.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?("#", "-")

          if (match = stripped.match(/\A([a-zA-Z0-9_.-]+)\s*([><=!~]+.+)?\z/))
            deps << {
              name: match[1],
              version: match[2]&.strip,
              group: "default",
              source: "requirements.txt",
              raw_line: stripped
            }
          end
        end

        deps
      end

      def parse_go_mod(content)
        deps = []
        in_require = false

        content.each_line do |line|
          stripped = line.strip

          if stripped.start_with?("require (")
            in_require = true
            next
          end

          if stripped == ")"
            in_require = false
            next
          end

          if in_require
            if (match = stripped.match(/\A(\S+)\s+(\S+)/))
              deps << {
                name: match[1],
                version: match[2],
                group: "default",
                source: "go.mod",
                raw_line: stripped
              }
            end
          elsif (match = stripped.match(/\Arequire\s+(\S+)\s+(\S+)/))
            deps << {
              name: match[1],
              version: match[2],
              group: "default",
              source: "go.mod",
              raw_line: stripped
            }
          end
        end

        deps
      end

      def section_to_group(section)
        case section
        when "dependencies" then "default"
        when "devDependencies" then "dev"
        when "peerDependencies" then "peer"
        else section
        end
      end

      def scan_path
        @scan_path ||= options[:scan_path] || "."
      end
    end
  end
end
