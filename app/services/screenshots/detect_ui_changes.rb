# frozen_string_literal: true

module Screenshots
  # Determines whether a set of changed file paths includes UI-facing changes.
  #
  # UI-facing changes are defined as modifications to files that directly
  # affect what a user sees in the browser: views, stylesheets, JavaScript,
  # layout templates, and frontend components.
  #
  # Patterns can be supplied explicitly, resolved from a framework identifier,
  # or auto-detected from the repository contents.
  #
  # @example with defaults (Rails patterns)
  #   result = Screenshots::DetectUiChanges.call(changed_files: ["app/views/projects/index.html.erb"])
  #   result[:ui_changes?]  # => true
  #   result[:ui_files]     # => ["app/views/projects/index.html.erb"]
  #
  # @example with a specific framework
  #   result = Screenshots::DetectUiChanges.call(
  #     changed_files: ["components/Button.tsx"],
  #     framework: :nextjs
  #   )
  #
  # @example with custom patterns
  #   result = Screenshots::DetectUiChanges.call(
  #     changed_files: ["src/views/Home.vue"],
  #     patterns: [%r{src/views/}],
  #     exclusions: []
  #   )
  class DetectUiChanges
    # @param changed_files [Array<String>] list of file paths changed in the PR
    # @param framework [Symbol, nil] framework identifier (e.g. :rails, :nextjs)
    # @param patterns [Array<Regexp>, nil] custom inclusion patterns (overrides framework)
    # @param exclusions [Array<Regexp>, nil] custom exclusion patterns (overrides framework)
    # @param repo_path [String, nil] repo root for framework auto-detection
    # @return [Hash] with :ui_changes? boolean and :ui_files array
    def self.call(changed_files:, framework: nil, patterns: nil, exclusions: nil, repo_path: nil)
      new(changed_files:, framework:, patterns:, exclusions:, repo_path:).call
    end

    def initialize(changed_files:, framework: nil, patterns: nil, exclusions: nil, repo_path: nil)
      @changed_files = Array(changed_files)
      @patterns = patterns
      @exclusions = exclusions
      @framework = framework
      @repo_path = repo_path
    end

    def call
      ui_files = @changed_files.select { |path| ui_file?(path) }

      {
        ui_changes?: ui_files.any?,
        ui_files: ui_files
      }
    end

    private

    def resolved_patterns
      @resolved_patterns ||= begin
        fw = resolve_framework_patterns
        fw[:patterns]
      end
    end

    def resolved_exclusions
      @resolved_exclusions ||= begin
        fw = resolve_framework_patterns
        fw[:exclusions]
      end
    end

    def resolve_framework_patterns
      @resolve_framework_patterns ||= if @patterns
        { patterns: @patterns, exclusions: @exclusions || [] }
      else
        framework = @framework || detect_or_default_framework
        FrameworkPatterns.for(framework)
      end
    end

    def detect_or_default_framework
      return DetectFramework.call(repo_path: @repo_path) if @repo_path

      :rails
    end

    def ui_file?(path)
      return false if resolved_exclusions.any? { |pattern| pattern.match?(path) }

      resolved_patterns.any? { |pattern| pattern.match?(path) }
    end
  end
end
