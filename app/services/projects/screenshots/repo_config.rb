# frozen_string_literal: true

require "psych"

module Projects
  module Screenshots
    class RepoConfig
      YAML_MAX_SIZE = 64_000

      Result = Struct.new(:config, :content, :error, keyword_init: true)

      attr_reader :project, :path

      def initialize(project:, path:)
        @project = project
        @path = path.presence || Project::DEFAULT_SCREENSHOT_SETTINGS["config_path"]
      end

      def self.call(...)
        new(...).call
      end

      def call
        content = fetch_content
        return Result.new(config: {}, content: nil, error: oversized_error) if content&.bytesize.to_i > YAML_MAX_SIZE

        Result.new(
          config: normalize_config(parse_yaml(content)),
          content: content,
          error: nil
        )
      rescue GithubClient::NotFoundError
        Result.new(config: {}, content: nil, error: nil)
      rescue GithubClient::Error, Psych::Exception => e
        Result.new(config: {}, content: nil, error: e.message)
      end

      private

      def parse_yaml(content)
        return {} if content.blank?

        Psych.safe_load(content, aliases: false) || {}
      end

      def normalize_config(config)
        hash = config.is_a?(Hash) ? config.deep_stringify_keys : {}

        {
          "driver" => hash["driver"].presence,
          "auto_capture" => boolean_or_nil(hash["auto_capture"]),
          "services" => normalize_array(hash["services"] || hash["service_dependencies"]),
          "setup" => normalize_array(hash["setup"] || hash["setup_commands"])
        }.compact
      end

      def normalize_array(value)
        Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      end

      def boolean_or_nil(value)
        return nil unless [ true, false, "true", "false", "1", "0", 1, 0 ].include?(value)

        ActiveModel::Type::Boolean.new.cast(value)
      end

      def oversized_error
        "#{path} is too large to parse safely."
      end

      def fetch_content
        project.github_token.client.file_content(project.full_name, path: path)
      rescue Exception => e
        raise unless webmock_request_blocked?(e)

        nil
      end

      def webmock_request_blocked?(error)
        defined?(WebMock::NetConnectNotAllowedError) && error.is_a?(WebMock::NetConnectNotAllowedError)
      end
    end
  end
end
