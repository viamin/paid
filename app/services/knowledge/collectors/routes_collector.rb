# frozen_string_literal: true

module Knowledge
  module Collectors
    class RoutesCollector < BaseCollector
      SCOPE_PATH = "config/routes.rb"
      BUNDLE_HOME = "/tmp/paid-bundle-home"
      SQLITE3_GEMFILE_PATTERN = /^\s*gem(?:\s+|\s*\()\s*["']sqlite3["']/.freeze
      SQLITE3_LOCKFILE_PATTERN = /^\s{2,4}sqlite3(?:\s|\(|$)/.freeze
      # Exception class names that indicate database issues preventing
      # `bin/rails routes` from booting. Checked against both
      # error.class.name (local execution) and error.message (containerized
      # execution, where ContainerError wraps the original class name).
      DATABASE_ERROR_CLASS_NAMES = [
        "ActiveRecord::ConnectionNotEstablished",
        "ActiveRecord::DatabaseConnectionError",
        "ActiveRecord::NoDatabaseError",
        "ActiveRecord::AdapterNotFound",
        "Mysql2::Error::ConnectionError",
        "SQLite3::CantOpenException",
        "Sequel::DatabaseConnectionError",
        "PG::ConnectionBad"
      ].freeze

      # Message patterns that indicate database issues preventing
      # `bin/rails routes` from booting. Intentionally narrow to avoid
      # false-positives from non-DB services that use similar wording.
      DATABASE_ERROR_MESSAGE_PATTERNS = [
        /connection to server .+(?:PGSQL|PostgreSQL|5432).* failed/i,
        /could not connect to server:.*(?:PostgreSQL|5432|pg_hba)/i,
        /can't connect to (?:local )?MySQL server/i,
        /unknown database/i,
        /unable to open database file/i,
        /no such database/i,
        /database .* does not exist/i,
        /database adapter.*(?:not found|not loaded)/i,
        /Error loading the .+ Active Record adapter/,
        /(?:Active Record adapter|database adapter).*is not part of the bundle/m,
        /no such table/i,
        /Cannot load database configuration:/i
      ].freeze

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

        unless sqlite3_available_for_in_memory_routes?
          skip!(
            "routes require sqlite3 support for in-memory boot fallback",
            preserve_existing_artifacts: true
          )
        end

        # Install gems so `bin/rails routes` can boot the application.
        # The container workspace is read-only, so gems are installed to
        # /tmp/bundle (a writable tmpfs mount).
        # Network is temporarily enabled for bundle install, then disabled.
        # install_gems_in_container also removes the temporary HOME used for
        # git config before returning, so `bin/rails routes` never runs with
        # install-time git settings lingering on disk.
        if repo_file_exists?("Gemfile")
          install_gems_in_container
        end

        run_routes_command
      rescue StandardError => error
        raise unless routes_boot_error?(error)

        # Always preserve prior route artifacts on DB skip. We cannot
        # reliably detect whether config/routes.rb changed: containerized
        # runs use shallow clones (--depth 1) so the parent tree needed
        # by git diff-tree is absent, and even with full history we would
        # only compare HEAD vs its parent, missing multi-commit batches.
        # Preserving stale routes is preferable to losing them entirely;
        # the next successful collection will correct any drift.
        skip!(
          "routes require database access during Rails boot",
          preserve_existing_artifacts: true
        )
      end

      def run_routes_command
        run_command(
          "sh", "-c",
          "bin/rails routes --expanded",
          timeout: 120,
          env: routes_command_env
        )
      end

      def routes_command_env
        {
          "DATABASE_URL" => "sqlite3::memory:",
          "BUNDLE_PATH" => "/tmp/bundle",
          "BUNDLE_APP_CONFIG" => "/tmp/bundle-config"
        }
      end

      def install_gems_in_container
        network_connected = false
        original_error = nil
        container_runner.connect_network!
        network_connected = true
        run_command(
          "sh", "-c",
          install_bundle_command,
          timeout: 300,
          env: install_bundle_env
        )
      rescue StandardError => error
        original_error = error
        raise
      ensure
        cleanup_bundle_install_state(network_connected:, original_error:)
      end

      def install_bundle_command
        "mkdir -p #{BUNDLE_HOME} && " \
          "git config --global --add url.\\\"https://github.com/\\\".insteadOf ssh://git@github.com/ && " \
          "git config --global --add url.\\\"https://github.com/\\\".insteadOf git@github.com: && " \
          "bundle install --jobs 4 --retry 3"
      end

      def sqlite3_available_for_in_memory_routes?
        gemfile_lock_includes_sqlite3? || gemfile_declares_sqlite3?
      end

      def gemfile_lock_includes_sqlite3?
        return false unless repo_file_exists?("Gemfile.lock")

        read_repo_file("Gemfile.lock").match?(SQLITE3_LOCKFILE_PATTERN)
      end

      def gemfile_declares_sqlite3?
        return false unless repo_file_exists?("Gemfile")

        read_repo_file("Gemfile").match?(SQLITE3_GEMFILE_PATTERN)
      end

      def install_bundle_env
        {
          "HOME" => BUNDLE_HOME,
          "BUNDLE_PATH" => "/tmp/bundle",
          "BUNDLE_APP_CONFIG" => "/tmp/bundle-config",
          "BUNDLE_FROZEN" => "true"
        }
      end

      def cleanup_bundle_home_in_container
        run_command(
          "sh", "-c",
          "rm -rf #{BUNDLE_HOME} && " \
          "! test -e #{BUNDLE_HOME}",
          timeout: 10,
          env: { "HOME" => BUNDLE_HOME }
        )
      end

      def cleanup_bundle_install_state(network_connected:, original_error:)
        return unless network_connected

        teardown_error = nil

        begin
          cleanup_bundle_home_in_container
        rescue StandardError => error
          teardown_error ||= error
        ensure
          begin
            container_runner.disconnect_network!
          rescue StandardError => error
            teardown_error ||= error
          end
        end

        raise teardown_error if original_error.nil? && teardown_error
      end

      def routes_boot_error?(error)
        each_error_in_chain(error).any? do |current_error|
          matches_database_error_class?(current_error) ||
            matches_database_error_message?(current_error)
        end
      end

      # Checks both the actual class (local execution) and whether the
      # class name appears in the message (containerized execution, where
      # ContainerizedRunner::ContainerError embeds the original error text).
      def matches_database_error_class?(error)
        message = error.message.to_s

        DATABASE_ERROR_CLASS_NAMES.any? do |class_name|
          error.class.name == class_name || message.include?(class_name)
        end
      end

      def matches_database_error_message?(error)
        message = error.message.to_s

        DATABASE_ERROR_MESSAGE_PATTERNS.any? { |pattern| message.match?(pattern) }
      end

      def each_error_in_chain(error)
        [].tap do |errors|
          current_error = error

          while current_error && !errors.include?(current_error)
            errors << current_error
            current_error = current_error.cause
          end
        end
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
