# frozen_string_literal: true

require "find"

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
    SKIP_DIRECTORIES = %w[.git node_modules vendor tmp log].freeze

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
      next_config? && nextjs_ui_root?
    end

    def django?
      file_exists?("manage.py") && any_match?(%r{templates/})
    end

    def next_config?
      any_match?(%r{\Anext\.config\.[jt]s\z}) || any_match?(%r{\Anext\.config\.mjs\z})
    end

    def nextjs_ui_root?
      %w[app pages src/app src/pages].any? { |path| file_exists?(path) }
    end

    def file_exists?(path)
      candidate_entries.any? { |f| f == path || f.start_with?("#{path}/") }
    end

    def any_match?(pattern)
      candidate_entries.any? { |f| pattern.match?(f) }
    end

    def candidate_entries
      @candidate_entries ||= if @file_list
        Array(@file_list)
      elsif @repo_path
        scan_repo_entries
      else
        []
      end
    end

    def scan_repo_entries
      prefix = "#{@repo_path}/"

      Find.find(@repo_path).each_with_object([]) do |path, entries|
        next if path == @repo_path

        relative_path = path.delete_prefix(prefix)

        if File.directory?(path) && SKIP_DIRECTORIES.include?(relative_path.split("/").first)
          Find.prune
        end

        entries << relative_path
      end
    end
  end
end
