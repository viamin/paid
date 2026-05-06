# frozen_string_literal: true

module Screenshots
  # Auto-detects the web framework of a repository by examining file presence.
  #
  # @example
  #   Screenshots::DetectFramework.call(repo_path: "/path/to/repo")
  #   # => :rails
  #
  #   Screenshots::DetectFramework.call(file_list: ["next.config.js", "app/page.tsx"])
  #   # => :nextjs
  class DetectFramework
    # @param repo_path [String, nil] path to the repo root (checks filesystem)
    # @param file_list [Array<String>, nil] list of repo file paths (avoids filesystem)
    # @return [Symbol] detected framework identifier
    def self.call(repo_path: nil, file_list: nil)
      new(repo_path:, file_list:).call
    end

    def initialize(repo_path: nil, file_list: nil)
      @repo_path = repo_path
      @file_list = file_list
    end

    def call
      return :rails if rails?
      return :nextjs if nextjs?
      return :django if django?

      :generic
    end

    private

    def rails?
      file_exists?("config/routes.rb") && file_exists?("app/views")
    end

    def nextjs?
      next_config? && (file_exists?("app") || file_exists?("pages"))
    end

    def django?
      file_exists?("manage.py") && any_match?(%r{templates/})
    end

    def next_config?
      any_match?(%r{\Anext\.config\.[jt]s\z}) || any_match?(%r{\Anext\.config\.mjs\z})
    end

    def file_exists?(path)
      if @file_list
        @file_list.any? { |f| f == path || f.start_with?("#{path}/") }
      elsif @repo_path
        File.exist?(File.join(@repo_path, path))
      else
        false
      end
    end

    def any_match?(pattern)
      if @file_list
        @file_list.any? { |f| pattern.match?(f) }
      elsif @repo_path
        Dir.glob(File.join(@repo_path, "**/*")).any? { |f| pattern.match?(f.delete_prefix("#{@repo_path}/")) }
      else
        false
      end
    end
  end
end
