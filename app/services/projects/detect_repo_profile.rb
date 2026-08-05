# frozen_string_literal: true

require "find"

module Projects
  class DetectRepoProfile
    SKIP_DIRECTORIES = %w[.git node_modules vendor tmp log dist build coverage].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, repo_path:)
      @project = project
      @repo_path = repo_path
    end

    def call
      manifest = Projects::RepoProfileConfig.call(repo_path: repo_path)
      detected = detected_profile

      Projects::RepoProfile.normalize(
        detected.merge(
          "languages" => manifest["languages"].presence || detected["languages"],
          "test_languages" => manifest["test_languages"].presence || detected["test_languages"],
          "framework" => manifest["framework"].presence || detected["framework"],
          "manifest_path" => manifest["manifest_path"]
        ),
        primary_language: project.primary_language,
        screenshot_framework: project.effective_screenshot_settings.dig("detection", "framework")
      )
    end

    private

    attr_reader :project, :repo_path

    def detected_profile
      languages, marker_files = detect_languages

      {
        "languages" => languages,
        "test_languages" => Projects::RepoProfile.default_test_languages(languages),
        "framework" => detected_framework,
        "confidence" => detected_framework.present? ? 0.95 : nil,
        "detected_at" => Time.current.iso8601,
        "source" => "repo_scan",
        "marker_files" => marker_files
      }
    end

    def detect_languages
      files = repo_files
      languages = []
      marker_files = []

      if files.include?("Gemfile") || files.any? { |path| path.end_with?(".gemspec") }
        languages << "ruby"
        marker_files << "Gemfile" if files.include?("Gemfile")
      end

      if files.include?("package.json")
        languages << "javascript"
        marker_files << "package.json"
      end

      if files.include?("tsconfig.json") || files.any? { |path| path.end_with?(".ts", ".tsx") }
        languages << "typescript"
        marker_files << "tsconfig.json" if files.include?("tsconfig.json")
      end

      if files.include?("pyproject.toml") || files.include?("setup.py") || files.include?("manage.py") ||
          files.any? { |path| path.match?(/(^|\/)requirements.*\.txt$/) }
        languages << "python"
        marker_files.concat(files & %w[pyproject.toml setup.py manage.py])
      end

      if files.include?("go.mod")
        languages << "go"
        marker_files << "go.mod"
      end

      if files.include?("Cargo.toml")
        languages << "rust"
        marker_files << "Cargo.toml"
      end

      if files.include?("mix.exs")
        languages << "elixir"
        marker_files << "mix.exs"
      end

      if files.include?("Package.swift")
        languages << "swift"
        marker_files << "Package.swift"
      end

      [ languages.uniq, marker_files.uniq ]
    end

    def detected_framework
      framework = Screenshots::DetectFramework.detect_framework_only(repo_path:)
      framework == :generic ? nil : framework.to_s
    end

    def repo_files
      @repo_files ||= begin
        paths = []

        Find.find(repo_path) do |path|
          relative = path.delete_prefix("#{repo_path}/")
          next if relative.blank?

          if File.directory?(path)
            if SKIP_DIRECTORIES.include?(File.basename(path))
              Find.prune
            else
              next
            end
          else
            paths << relative
          end
        end

        paths
      end
    end
  end
end
