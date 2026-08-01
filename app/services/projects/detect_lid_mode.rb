# frozen_string_literal: true

module Projects
  class DetectLidMode
    INSTRUCTION_FILES = %w[AGENTS.md CLAUDE.md].freeze
    LID_MODES = %w[full scoped].freeze
    FULL_MODE = "full"
    SCOPED_MODE = "scoped"
    LID_HEADER = /^##\s+LID\s*$/
    LID_SCOPE_HEADER = /^##\s+LID Scope\s*$/
    INVALID_MODE_WARNING = "Invalid LID mode in %s; defaulted to Full."
    MISSING_SCOPE_WARNING = "Scoped LID declared without a ## LID Scope section; defaulting future scope checks to in-scope."

    def self.call(...)
      new(...).call
    end

    def self.from_project_repository(project:, force: false)
      worktree_service = WorktreeService.new(project)
      worktree_service.ensure_cloned
      commit_sha = worktree_service.current_commit_sha

      worktree_service.with_temporary_checkout(commit_sha) do |checkout_path|
        call(project:, repo_path: checkout_path, force:)
      end
    end

    def initialize(project:, repo_path:, force: false)
      @project = project
      @repo_path = Pathname(repo_path)
      @warnings = []
      @force = force
    end

    # @spec LID-DETECTION-001
    # @spec LID-DETECTION-002
    # @spec LID-DETECTION-003
    # @spec LID-DETECTION-004
    # @spec LID-DETECTION-005
    def call
      result = instruction_file_detection || artifact_detection || absent_detection
      persist!(result)
      result
    end

    private

    attr_reader :project, :repo_path, :warnings, :force

    def instruction_file_detection
      INSTRUCTION_FILES.each do |relative_path|
        path = repo_path.join(relative_path)
        next unless path.file?

        contents = path.read
        lid_block = extract_section(contents, LID_HEADER)
        next unless lid_block

        return lid_detection_from_block(path, contents, lid_block)
      end

      nil
    end

    def lid_detection_from_block(instruction_file, contents, lid_block)
      mode = parse_mode(lid_block, instruction_file.basename.to_s)
      version = parse_bullet(lid_block, "Version")
      warnings << MISSING_SCOPE_WARNING if mode == SCOPED_MODE && extract_section(contents, LID_SCOPE_HEADER).blank?

      {
        mode: mode,
        version: version,
        sources: [ "#{instruction_file.basename} ## LID block" ],
        warnings: warnings.dup
      }
    end

    def artifact_detection
      sources = []
      sources << "docs/intent/" if lid_intent_content?
      sources << "docs/high-level-design.md" if repo_file?("docs/high-level-design.md")
      sources << "docs/arrows/index.yaml" if repo_file?("docs/arrows/index.yaml")
      return if sources.empty?

      {
        mode: FULL_MODE,
        version: nil,
        sources: sources,
        warnings: warnings.dup
      }
    end

    def absent_detection
      {
        mode: nil,
        version: nil,
        sources: [],
        warnings: warnings.dup
      }
    end

    # @spec LID-DETECTION-008
    # A manual override from project settings survives background detection
    # (import/sync) until the owner explicitly requests re-detection.
    def persist!(result)
      attrs = { lid_detection: detection_metadata(result) }
      attrs.merge!(lid_mode: result.fetch(:mode), lid_mode_overridden: false) if apply_detected_mode?
      project.update!(attrs)
    end

    def apply_detected_mode?
      force || !project.lid_mode_overridden?
    end

    def detection_metadata(result)
      {
        "version" => result[:version],
        "detected_at" => Time.current.iso8601,
        "sources" => result.fetch(:sources),
        "warnings" => result.fetch(:warnings),
        "scope_defaults_to_in_scope" => scoped_without_scope?(result)
      }
    end

    def scoped_without_scope?(result)
      result[:mode] == SCOPED_MODE && result.fetch(:warnings).include?(MISSING_SCOPE_WARNING)
    end

    def parse_mode(lid_block, file_name)
      mode = parse_bullet(lid_block, "Mode").to_s.downcase
      return mode if LID_MODES.include?(mode)

      warnings << format(INVALID_MODE_WARNING, file_name)
      FULL_MODE
    end

    def parse_bullet(section, label)
      section.each_line do |line|
        match = line.match(/^\s*-\s*#{Regexp.escape(label)}:\s*(.+?)\s*$/i)
        return match[1].strip if match
      end

      nil
    end

    def extract_section(contents, header_pattern)
      lines = contents.lines
      header_index = lines.index { |line| line.match?(header_pattern) }
      return if header_index.nil?

      lines[(header_index + 1)..].to_a.take_while { |line| !line.match?(/^##\s+/) }.join
    end

    def lid_intent_content?
      intent_path = repo_path.join("docs/intent")
      intent_path.directory? && intent_path.children.any?
    end

    def repo_file?(relative_path)
      repo_path.join(relative_path).file?
    end
  end
end
