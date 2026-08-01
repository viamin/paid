# frozen_string_literal: true

require "open3"

module Lid
  # @spec LID-PR-CONFIRM-001
  # @spec LID-PR-CONFIRM-002
  class BuildInferenceChecklist
    CHECKLIST_HEADING = "## Confirm These Inferred Decisions"
    OPEN_QUESTIONS_HEADING = /^##\s+Open Questions\b/i
    SECTION_HEADING = /^\#{1,6}\s+/
    INSTRUCTION_FILES = %w[AGENTS.md CLAUDE.md .github/copilot-instructions.md].freeze
    MAX_ITEMS = 20

    def self.call(...)
      new(...).call
    end

    # A docs-only Planning PR is identified by its live diff, not by whether
    # the PR body still carries the appended checklist heading. The body is a
    # snapshot that can be edited or trimmed independently of the branch, so
    # the branch contents (the changed files) remain the source of truth —
    # mirroring the criteria the checklist builder gates on at PR-creation time.
    def self.docs_only_planning_pr?(changed_files:)
      docs_only_paths?(changed_files)
    end

    def self.docs_only_paths?(changed_files)
      paths = normalize_changed_files(changed_files)
      paths.present? && paths.all? { |path| markdown_or_instruction_file?(path) }
    end

    def self.normalize_changed_files(changed_files)
      Array(changed_files).filter_map do |entry|
        case entry
        when String
          entry
        when Hash
          entry[:filename] || entry["filename"]
        else
          entry.filename if entry.respond_to?(:filename)
        end
      end.reject(&:blank?)
    end

    def self.markdown_or_instruction_file?(path)
      planning_doc_file?(path) || INSTRUCTION_FILES.include?(path)
    end

    def self.planning_doc_file?(path)
      path == "docs/high-level-design.md" || path.start_with?("docs/intent/")
    end

    def initialize(worktree_path:, base_commit_sha:, max_items: MAX_ITEMS)
      @worktree_path = worktree_path
      @base_commit_sha = base_commit_sha
      @max_items = max_items
    end

    def call
      return "" if worktree_path.blank? || base_commit_sha.blank? || !Dir.exist?(worktree_path)
      return "" unless docs_only_diff?

      items = inferred_items + open_question_items
      return "" if items.empty?

      render(items.first(max_items))
    end

    private

    attr_reader :worktree_path, :base_commit_sha, :max_items

    # Scopes the checklist to genuine docs-only Planning PRs (RDR-051 phase 4):
    # an ordinary implementation PR that happens to touch LID docs alongside
    # code changes must not be misclassified as a Planning PR downstream.
    def docs_only_diff?
      self.class.docs_only_paths?(changed_files)
    end

    def inferred_items
      changed_markdown_files.flat_map do |path|
        changed_lines(path).filter_map do |line|
          next unless line[:text].include?("[inferred]")

          checklist_item(path, normalize_inferred_line(line[:text]))
        end
      end
    end

    def open_question_items
      changed_markdown_files.flat_map do |path|
        extract_open_questions(path).filter_map do |line|
          checklist_item(path, "Open question: #{normalize_open_question(line[:text])}")
        end
      end
    end

    def checklist_item(path, text)
      return if text.blank?

      "- [ ] `#{path}`: #{text}"
    end

    def normalize_inferred_line(line)
      clean_line(line)
        .sub(/\s*\[inferred\]\s*/i, " ")
        .gsub(/\s+/, " ")
        .strip
    end

    def normalize_open_question(line)
      clean_line(line)
        .sub(/\A(?:[-*+]\s+|\d+\.\s+|\[[ xX]\]\s+)/, "")
        .gsub(/\s+/, " ")
        .strip
    end

    def clean_line(line)
      line.to_s
        .delete("|")
        .gsub(/[`*_]/, "")
        .strip
    end

    def extract_open_questions(path)
      lines = read_lines(path)
      start_index = lines.index { |line| line.match?(OPEN_QUESTIONS_HEADING) }
      return [] unless start_index

      changed_line_numbers_for(path).filter_map do |line_number|
        next if line_number <= start_index

        line = lines[line_number]
        next if line.blank?
        next unless open_question_line?(line)
        next unless within_open_questions_section?(lines, start_index, line_number)

        { number: line_number, text: line }
      end
    end

    def within_open_questions_section?(lines, start_index, line_number)
      lines[(start_index + 1)...line_number].none? { |line| line.match?(SECTION_HEADING) }
    end

    def open_question_line?(line)
      line.strip.start_with?("-", "*", "+") || line.strip.match?(/\A\d+\./) || line.strip.match?(/\A\[[ xX]\]/)
    end

    def changed_lines(path)
      line_numbers = changed_line_numbers_for(path)
      return [] if line_numbers.empty?

      lines = read_lines(path)
      line_numbers.filter_map do |line_number|
        line = lines[line_number]
        next if line.nil?

        { number: line_number, text: line }
      end
    end

    def changed_line_numbers_for(path)
      @changed_line_numbers ||= {}
      @changed_line_numbers[path] ||= parse_changed_line_numbers(path)
    end

    def parse_changed_line_numbers(path)
      stdout, stderr, status = Open3.capture3(
        "git", "diff", "--unified=0", base_commit_sha, "--", path,
        chdir: worktree_path
      )

      raise "Failed to diff changed lines for #{path}: #{stderr.presence || stdout}" unless status.success?

      stdout.each_line.with_object([]) do |line, changed_lines|
        next unless (match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/))

        start_line = match[1].to_i
        line_count = match[2] ? match[2].to_i : 1
        next if line_count.zero?

        changed_lines.concat(((start_line - 1)...(start_line + line_count - 1)).to_a)
      end
    end

    def changed_markdown_files
      @changed_markdown_files ||= changed_files.select { |path| markdown_or_instruction_file?(path) }
    end

    def changed_files
      @changed_files ||= begin
        stdout, stderr, status = Open3.capture3(
          "git", "diff", "--name-only", base_commit_sha,
          chdir: worktree_path
        )

        raise "Failed to list changed files: #{stderr.presence || stdout}" unless status.success?

        stdout.lines.map(&:strip).reject(&:blank?)
      end
    end

    def markdown_or_instruction_file?(path)
      self.class.markdown_or_instruction_file?(path)
    end

    def planning_doc_file?(path)
      self.class.planning_doc_file?(path)
    end

    def read_lines(path)
      absolute_path = File.join(worktree_path, path)
      return [] unless File.file?(absolute_path)

      File.readlines(absolute_path, chomp: true)
    end

    def render(items)
      <<~MARKDOWN.rstrip
        #{CHECKLIST_HEADING}

        #{items.join("\n")}
      MARKDOWN
    end
  end
end
