# frozen_string_literal: true

module Knowledge
  module Collectors
    class RoutesCollector < BaseCollector
      SCOPE_PATH = "config/routes.rb"

      def collect
        output = read_routes_output
        skip!(skip_reason) if output.blank?

        parse_expanded_output(output).map do |route|
          build_artifact(route)
        end
      end

      def collector_type
        "routes"
      end

      private

      def skip_reason
        unless repo_file_exists?("config/routes.rb")
          return "not a Rails project (no config/routes.rb)"
        end

        "routes file not generated (tmp/routes_expanded.txt not found)"
      end

      def read_routes_output
        # Check for an explicit routes file path (e.g. passed via options).
        # This is an absolute path — used directly without repo path resolution.
        routes_file = options[:routes_file]
        if routes_file && File.exist?(routes_file)
          return File.read(routes_file)
        end

        # Fall back to the pre-generated expanded routes file within the repo.
        expanded_path = File.join("tmp", "routes_expanded.txt")
        if repo_file_exists?(expanded_path)
          return read_repo_file(expanded_path)
        end

        nil
      end

      def parse_expanded_output(output)
        routes = []
        current = {}

        output.each_line do |line|
          line = line.strip

          if line.start_with?("--[ Route")
            routes << current unless current.empty?
            current = {}
          elsif (match = line.match(/\A(\w+)\s*\|\s*(.*)\z/))
            key = match[1].strip.downcase
            value = match[2].strip
            case key
            when "prefix"
              current[:prefix] = value
            when "verb"
              current[:verb] = value
            when "uri"
              current[:uri] = clean_uri(value)
            when "controller"
              current[:controller_action] = value
            end
          end
        end

        routes << current unless current.empty?
        routes.select { |r| r[:verb].present? && r[:uri].present? }
      end

      def clean_uri(uri)
        uri.sub(/\(\.:format\)\z/, "")
      end

      def build_artifact(route)
        verb = route[:verb]
        path = route[:uri]
        identifier = "#{verb} #{path}"
        controller, action = (route[:controller_action] || "").split("#", 2)
        controller = controller.presence
        action = action&.presence
        prefix = route[:prefix]

        content = "#{verb} #{path}"
        content = "#{content} → #{controller}##{action}" if controller.present?
        content = "#{content} (prefix: #{prefix})" if prefix.present?

        chunk_lines = [ "Route: #{verb} #{path}" ]
        chunk_lines << "Controller: #{controller}##{action}" if controller.present?

        {
          artifact_type: "route",
          scope_path: SCOPE_PATH,
          identifier: identifier,
          content: content,
          metadata: {
            http_method: verb,
            path: path,
            controller: controller,
            action: action,
            prefix: prefix
          }.compact,
          chunks: [
            {
              chunk_type: "definition",
              content: chunk_lines.join("\n"),
              scope_tags: [ SCOPE_PATH ],
              sequence: 0
            }
          ]
        }
      end
    end
  end
end
