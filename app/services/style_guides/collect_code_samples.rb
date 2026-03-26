# frozen_string_literal: true

require "base64"

module StyleGuides
  # Fetches representative source code files from a project's GitHub repository.
  # Groups files by detected language and returns samples suitable for style
  # guide extraction via LLM analysis.
  #
  # @example
  #   result = StyleGuides::CollectCodeSamples.call(project: project)
  #   result # => { "ruby" => ["# frozen...\nclass Foo\n...", ...], ... }
  class CollectCodeSamples
    # Maximum total bytes of code samples to collect across all languages.
    MAX_TOTAL_BYTES = 80_000

    # Maximum bytes per individual file.
    MAX_FILE_BYTES = 15_000

    # Maximum number of files to sample per language.
    MAX_FILES_PER_LANGUAGE = 5

    # File extensions mapped to StyleGuide language identifiers.
    EXTENSION_LANGUAGE_MAP = {
      ".rb" => "ruby",
      ".rake" => "ruby",
      ".js" => "javascript",
      ".jsx" => "javascript",
      ".ts" => "typescript",
      ".tsx" => "typescript",
      ".py" => "python",
      ".go" => "go",
      ".rs" => "rust"
    }.freeze

    # Directories to skip during tree traversal.
    SKIP_DIRS = %w[
      vendor node_modules .git .github dist build tmp log coverage
      public/assets public/packs __pycache__ .bundle
    ].freeze

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      tree = fetch_tree
      return {} unless tree

      candidates = select_candidates(tree)
      grouped = group_by_language(candidates)
      fetch_samples(grouped)
    end

    private

    def fetch_tree
      client = project.github_token.client
      ref = project.default_branch || "main"
      client.tree(project.full_name, ref, recursive: true)
    rescue GithubClient::Error, Octokit::Error
      nil
    end

    def select_candidates(tree)
      blobs = Array(tree.tree).select { |item| item.type == "blob" }

      blobs.select do |blob|
        ext = File.extname(blob.path).downcase
        next false unless EXTENSION_LANGUAGE_MAP.key?(ext)
        next false if skip_path?(blob.path)
        next false if blob.size.to_i > MAX_FILE_BYTES
        next false if blob.size.to_i < 50

        true
      end
    end

    def skip_path?(path)
      parts = path.split("/")

      # Match single-segment entries (e.g., "vendor", "tmp")
      return true if parts.any? { |part| SKIP_DIRS.include?(part) }

      # Match multi-segment entries (e.g., "public/assets", "public/packs")
      SKIP_DIRS.any? do |dir|
        next false unless dir.include?("/")

        path == dir || path.start_with?("#{dir}/")
      end
    end

    def group_by_language(candidates)
      grouped = {}

      candidates.each do |blob|
        ext = File.extname(blob.path).downcase
        lang = EXTENSION_LANGUAGE_MAP[ext]
        grouped[lang] ||= []
        grouped[lang] << blob
      end

      # Sort each language group by file size descending to prefer
      # substantial files, then take up to MAX_FILES_PER_LANGUAGE.
      grouped.transform_values do |blobs|
        blobs.sort_by { |b| -b.size.to_i }.first(MAX_FILES_PER_LANGUAGE)
      end
    end

    def fetch_samples(grouped)
      client = project.github_token.client
      repo = project.full_name
      total_bytes = 0
      samples = {}

      grouped.each do |language, blobs|
        samples[language] = []

        blobs.each do |blob|
          break if total_bytes >= MAX_TOTAL_BYTES

          content = fetch_file_content(client, repo, blob.path)
          next unless content

          truncated = content.byteslice(0, MAX_FILE_BYTES)&.scrub("")
          total_bytes += truncated.bytesize
          samples[language] << { path: blob.path, content: truncated }
        end
      end

      # Remove languages with no successfully fetched samples
      samples.reject { |_, v| v.empty? }
    end

    def fetch_file_content(client, repo, path)
      response = client.contents(repo, path: path)
      return nil unless response&.content

      Base64.decode64(response.content).force_encoding("UTF-8").scrub("")
    rescue GithubClient::Error, Octokit::Error
      nil
    end
  end
end
