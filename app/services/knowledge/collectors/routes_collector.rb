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
        if options[:routes_file].present?
          return "routes_file not found or empty (#{options[:routes_file]})"
        end

        return "repository path not available" if resolve_repo_path.nil?

        unless repo_file_exists?("config/routes.rb")
          return "not a Rails project (no config/routes.rb)"
        end

        unless repo_file_exists?("bin/rails")
          return "bin/rails binstub not found — cannot generate routes"
        end

        "routes output was blank after running bin/rails routes"
      end

      def read_routes_output
        # When an explicit routes file path is provided (e.g. via options),
        # use it directly. If the file doesn't exist, return nil so the
        # caller skip!s — silently falling back to `bin/rails routes` would
        # be surprising when the caller intended a specific file.
        routes_file = options[:routes_file]
        if routes_file
          return File.exist?(routes_file) ? File.read(routes_file) : nil
        end

        # Generate routes by running the rails command directly.
        generate_routes_output
      end

      def generate_routes_output
        # Guard: if no repo path is available, repo_file_exists? would fall
        # back to process-relative paths, producing incorrect results.
        return nil unless resolve_repo_path

        # Guard: skip non-Rails repos that lack a routes file or rails binstub.
        # This check runs before the containerized? gate so that non-Rails
        # repos cause this method to return nil; the caller treats blank output
        # as a signal to skip! rather than "complete with 0 artifacts".
        unless repo_file_exists?(SCOPE_PATH) && repo_file_exists?("bin/rails")
          return nil
        end

        # Running `bin/rails routes` executes arbitrary Ruby from the target
        # repo (initializers, config, etc.). Only allow this inside a
        # sandboxed container to avoid executing untrusted code on the host.
        # Raise so CollectorRunner marks the run as failed rather than
        # silently completing with zero artifacts (which would leave
        # previously collected routes stale).
        unless containerized?
          raise "routes collector requires containerized mode — failing on host for security"
        end

        run_command("bin/rails", "routes", "--expanded", timeout: 60)
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
