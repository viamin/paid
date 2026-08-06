# frozen_string_literal: true

require "json"
require "uri"

module Screenshots
  class RuntimePlan
    Result = Data.define(
      :config,
      :framework,
      :setup_commands,
      :start_command,
      :base_url,
      :app_port,
      :readiness_host,
      :readiness_path
    ) do
      def start_command_available?
        start_command.present?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, repo_path:, config: nil)
      @project = project
      @repo_path = repo_path
      @config = config
    end

    def call
      Result.new(
        config: config,
        framework: detected_framework,
        setup_commands: config.setup_commands,
        start_command: application_start_command,
        base_url: config.base_url,
        app_port: app_port,
        readiness_host: readiness_host,
        readiness_path: readiness_path
      )
    end

    private

    attr_reader :project, :repo_path

    def config
      @config ||= Screenshots::ConfigParser.from_repo_path(repo_path, project:)
    end

    def detected_framework
      @detected_framework ||= begin
        overrides = Screenshots::ConfigParser.ui_detection_overrides(project:, repo_path:)
        framework = Projects::FrameworkProfile.normalize(overrides[:framework]) ||
          project.detected_framework
        framework&.to_sym || Screenshots::DetectFramework.detect_framework_only(repo_path:)
      end
    end

    def application_start_command
      port = app_port

      if File.exist?(File.join(repo_path, "bin/dev"))
        "PORT=#{port} bin/dev"
      elsif detected_framework == :rails && File.exist?(File.join(repo_path, "bin/rails"))
        "bundle exec bin/rails server -b 0.0.0.0 -p #{port}"
      elsif detected_framework == :phoenix && File.exist?(File.join(repo_path, "mix.exs"))
        "PORT=#{port} MIX_ENV=dev mix phx.server"
      elsif detected_framework == :django && File.exist?(File.join(repo_path, "manage.py"))
        "python3 manage.py runserver 0.0.0.0:#{port}"
      elsif detected_framework == :nextjs && package_dependency?("next")
        "yarn next dev --hostname 0.0.0.0 --port #{port}"
      elsif package_dependency?("vite")
        "yarn vite --host 0.0.0.0 --port #{port}"
      elsif File.exist?(File.join(repo_path, "package.json"))
        "yarn dev --host 0.0.0.0 --port #{port}"
      end
    end

    def app_port
      uri = URI.parse(config.base_url || Screenshots::Configuration::DEFAULT_BASE_URL)
      uri.port || 3000
    end

    def readiness_host
      uri = URI.parse(config.base_url)
      uri.host.presence || "127.0.0.1"
    end

    def readiness_path
      uri = URI.parse(config.base_url)
      uri.path.presence || "/"
    end

    def package_dependency?(name)
      package_json_path = File.join(repo_path, "package.json")
      return false unless File.exist?(package_json_path)

      package_json = JSON.parse(File.read(package_json_path))
      %w[dependencies devDependencies].any? do |key|
        package_json.fetch(key, {}).key?(name)
      end
    rescue JSON::ParserError
      false
    end
  end
end
