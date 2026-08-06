# frozen_string_literal: true

require "psych"

module Projects
  class RepoProfileConfig
    DEFAULT_PATH = ".paid.yml"

    def self.call(...)
      new(...).call
    end

    def initialize(repo_path:, path: DEFAULT_PATH)
      @repo_path = repo_path
      @path = path
    end

    def call
      return {} unless File.file?(full_path)

      normalize(Psych.safe_load_file(full_path, aliases: false) || {})
    rescue Psych::Exception
      {}
    end

    private

    attr_reader :repo_path, :path

    def full_path
      File.join(repo_path, path)
    end

    def normalize(config)
      hash = config.is_a?(Hash) ? config.deep_stringify_keys : {}
      languages = hash["languages"].is_a?(Hash) ? hash["languages"] : {}

      {
        "languages" => normalize_languages(languages["all"] || languages["detected"] || hash["languages"]),
        "test_languages" => normalize_languages(languages["test"] || hash["test_languages"]),
        "framework" => Projects::FrameworkProfile.normalize(hash["framework"]),
        "manifest_path" => path
      }.compact
    end

    def normalize_languages(values)
      normalized = Projects::RepoProfile.normalize_languages(values)
      normalized.presence
    end
  end
end
