# frozen_string_literal: true

module Config
  # Production-only startup configuration validator.
  #
  # Runs from an `after_initialize` hook (see
  # `config/initializers/production_config.rb`) gated on `Rails.env.production?`.
  # It fails fast at boot when a required setting is absent or unsafe, and logs
  # a warning (without failing) when a development-unsafe default is detected.
  #
  # Required settings raise `ConfigurationError` listing *every* offending
  # setting at once, so a misconfigured deploy is diagnosed in a single boot
  # attempt instead of one-setting-at-a-time. Warnings are emitted for
  # development defaults that would silently degrade a cloud deploy (localhost
  # service addresses, a local container backend with no Docker socket, missing
  # screenshots storage).
  #
  # Development and test environments are entirely unaffected: the initializer
  # short-circuits before instantiating this class.
  #
  # The class is deliberately a pure, injectable object -- the constructor takes
  # already-resolved values rather than reading `ENV` / Rails config directly.
  # This keeps the production contract explicit in one place and makes every
  # branch (all-present, each-missing, localhost-warning) trivially testable
  # without booting a production Rails process. See `.from_environment` for the
  # single integration point that resolves the live values.
  #
  # @spec PROD-CONFIG-001
  class ProductionValidator
    # Raised at boot when one or more required production settings are absent or
    # unsafe. The message enumerates every problem so a single failed boot
    # surfaces the full repair list.
    class ConfigurationError < StandardError; end

    # Hosts that are only valid in development/test and signal a misconfigured
    # (or unset, defaulted) production deploy when seen in production.
    LOCALHOST_HOSTS = %w[localhost 127.0.0.1 0.0.0.0 ::1].freeze

    # Default Docker socket checked when CONTAINER_BACKEND=local.
    DEFAULT_DOCKER_SOCKET = "/var/run/docker.sock"

    # Rake tasks that run during image build / one-off bootstrap with no runtime
    # secrets intentionally available. The validator must skip these or it would
    # false-fail the Docker `assets:precompile` step (RAILS_ENV=production, no
    # DB password / Qdrant key). Runtime processes (server, bin/jobs,
    # bin/temporal_worker) and deploy-time tasks (db:prepare / db:migrate) DO
    # carry secrets and are intentionally validated.
    BUILD_ONLY_TASK_PREFIXES = %w[assets:].freeze

    class << self
      # Convenience entry point used by the initializer.
      def validate!(...)
        new(...).validate!
      end

      # True when the current process is a build/asset task that boots Rails in
      # the production environment without runtime secrets (e.g. the Docker
      # image's `SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile` step).
      def build_command?
        # @spec PROD-CONFIG-005
        invoked_tasks.any? { |task| BUILD_ONLY_TASK_PREFIXES.any? { |p| task.start_with?(p) } }
      end

      # Tasks invoked on the current Rake application plus raw ARGV, so the
      # detection works whether the command arrived via `bin/rails assets:*`
      # (Rake top-level tasks) or a direct rake invocation (ARGV).
      def invoked_tasks
        tasks = []
        tasks.concat(Rake.application.top_level_tasks.to_a) if defined?(Rake) && Rake.application
        tasks.concat(ARGV.grep(String))
      rescue StandardError
        []
      end

      # Resolve the live configuration values and validate them. This is the
      # single integration point that reads `ENV` / Rails config / credentials;
      # the validator instance itself stays pure. The Qdrant key comes from the
      # canonical `Paid.qdrant_api_key` reader so the validator and runtime
      # agree on the source of truth (credentials first, then `QDRANT_API_KEY`).
      def from_environment(logger: Rails.logger)
        new(
          database_url: ENV["DATABASE_URL"],
          database_password: ENV["PAID_DATABASE_PASSWORD"],
          temporal_address: Paid.temporal_address,
          redis_url: ENV["REDIS_URL"],
          qdrant_url: Paid.qdrant_url,
          qdrant_api_key: Paid.qdrant_api_key,
          workspace_root: Rails.application.config.x.workspace_root.to_s,
          workspace_writable: workspace_writable?(Rails.application.config.x.workspace_root.to_s),
          container_backend: ENV.fetch("CONTAINER_BACKEND", "local"),
          docker_socket_present: ENV["DOCKER_HOST"].present? || File.exist?(DEFAULT_DOCKER_SOCKET),
          screenshots_configured: Screenshots::Storage.configured?,
          logger: logger
        )
      end

      # True when the workspace root exists and is writable, or can be created
      # (best-effort `mkpath`). Surfaced as a warning: named-volume clones (the
      # default) do not need a host path, but legacy worktree execution does.
      def workspace_writable?(path)
        pathname = Pathname.new(path)
        return true if pathname.exist? && pathname.writable?

        pathname.mkpath
        pathname.writable?
      rescue SystemCallError
        false
      end
    end

    # The validator takes resolved values directly. The parameter count is
    # inherent to validating many independent settings in one pass; grouping
    # them behind a struct would only move the indirection without reducing it.
    def initialize(
      database_url:,
      database_password:,
      temporal_address:,
      redis_url:,
      qdrant_url:,
      qdrant_api_key:,
      workspace_root:,
      workspace_writable:,
      container_backend:,
      docker_socket_present:,
      screenshots_configured:,
      logger:
    )
      @database_url = database_url
      @database_password = database_password
      @temporal_address = temporal_address
      @redis_url = redis_url
      @qdrant_url = qdrant_url
      @qdrant_api_key = qdrant_api_key
      @workspace_root = workspace_root
      @workspace_writable = workspace_writable
      @container_backend = container_backend
      @docker_socket_present = docker_socket_present
      @screenshots_configured = screenshots_configured
      @logger = logger
      @errors = []
      @warnings = []
    end

    # Runs all checks, logs warnings, then raises if any required setting is
    # absent or unsafe. Returns `nil` (the validator is run for its side
    # effects).
    #
    # @spec PROD-CONFIG-001
    def validate!
      validate_required
      collect_warnings
      emit_warnings
      return if @errors.empty?

      raise ConfigurationError, error_message
    end

    private

    attr_reader :database_url, :database_password, :temporal_address, :redis_url,
                :qdrant_url, :qdrant_api_key, :workspace_root, :workspace_writable,
                :container_backend, :docker_socket_present, :screenshots_configured,
                :logger

    def validate_required
      # @spec PROD-CONFIG-002
      add_error(:database, "database connection (set DATABASE_URL or PAID_DATABASE_PASSWORD)") unless database_configured?
      add_error(:qdrant_api_key, "QDRANT_API_KEY (or qdrant.api_key credential)") if qdrant_api_key.blank?
    end

    def collect_warnings
      # @spec PROD-CONFIG-003
      add_warning("Temporal address resolves to localhost (#{temporal_address}); set TEMPORAL_ADDRESS/TEMPORAL_HOST to a production host") if localhost?(temporal_address)
      add_warning("Redis URL resolves to localhost (#{redis_url}); set REDIS_URL to a production host") if redis_localhost?
      add_warning("Qdrant URL resolves to localhost (#{qdrant_url}); set QDRANT_URL to a production host") if localhost?(qdrant_url)
      add_warning("CONTAINER_BACKEND=local but no Docker socket detected; mount the Docker socket or configure a remote backend") if local_backend_without_socket?
      add_warning("Workspace root is not writable (#{workspace_root}); set WORKSPACE_ROOT or ensure the path exists and is writable") unless workspace_writable
      add_warning("Screenshots storage is not configured; set SCREENSHOTS_S3_* credentials for screenshot/trace uploads") unless screenshots_configured
    end

    def database_configured?
      database_url.present? || database_password.present?
    end

    def redis_localhost?
      # An unset REDIS_URL falls back to the localhost default used by
      # `ClaudeLoginSessions::Coordination.redis` and
      # `config/initializers/rails_performance.rb`, so treat a blank value as
      # a localhost warning rather than a hard failure: Redis is only consumed
      # by optional coordination features in production (the app cache is
      # DB-backed via `solid_cache_store`). Warning is the safe level — the
      # first Redis call would surface a connection error if coordination is
      # actually wired up, but otherwise the deploy boots cleanly.
      redis_url.blank? || localhost?(redis_url)
    end

    def local_backend_without_socket?
      container_backend.to_s == "local" && !docker_socket_present
    end

    # True when the value is blank (unset, defaults to localhost) or its host
    # part is a development-only address.
    def localhost?(value)
      return true if value.to_s.strip.empty?

      LOCALHOST_HOSTS.include?(extract_host(value.to_s))
    end

    def extract_host(value)
      return URI.parse(value).host if value.include?("://")

      value.split(":", 2).first
    rescue URI::InvalidURIError
      value.split(":", 2).first
    end

    def add_error(setting, detail)
      @errors << "- #{setting}: #{detail}"
    end

    def add_warning(message)
      @warnings << message
    end

    def emit_warnings
      @warnings.each do |message|
        logger.warn(message: "production_config.unsafe_default", detail: message)
      end
    end

    def error_message
      <<~MSG.chomp
        Production configuration validation failed. Resolve all of the following required settings and restart:
        #{@errors.join("\n")}

        See docs/PRODUCTION_CONFIG.md for the complete required environment variable list.
      MSG
    end
  end
end
