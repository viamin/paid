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

    def self.checklist_appended?(body)
      body.to_s.include?(CHECKLIST_HEADING)
    end

    def initialize(worktree_path:, base_commit_sha:, max_items: MAX_ITEMS)
      @worktree_path = worktree_path
      @base_commit_sha = base_commit_sha
      @max_items = max_items
    end

    def call
      return "" if worktree_path.blank? || base_commit_sha.blank? || !Dir.exist?(worktree_path)

      items = inferred_items + open_question_items
      return "" if items.empty?

      render(items.first(max_items))
    end

    private

    attr_reader :worktree_path, :base_commit_sha, :max_items

    def inferred_items
      changed_markdown_files.flat_map do |path|
        read_lines(path).filter_map do |line|
          next unless line.include?("[inferred]")

          checklist_item(path, normalize_inferred_line(line))
        end
      end
    end

    def open_question_items
      changed_markdown_files.flat_map do |path|
        extract_open_questions(path).filter_map do |line|
          checklist_item(path, "Open question: #{normalize_open_question(line)}")
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

      lines[(start_index + 1)..].take_while { |line|
        !line.match?(SECTION_HEADING)
      }.select { |line|
        line.strip.start_with?("-", "*", "+") || line.strip.match?(/\A\d+\./) || line.strip.match?(/\A\[[ xX]\]/)
      }
    end

    def changed_markdown_files
      @changed_markdown_files ||= changed_files.select { |path| markdown_or_instruction_file?(path) }
    end

    def changed_files
      stdout, stderr, status = Open3.capture3(
        "git", "diff", "--name-only", base_commit_sha,
        chdir: worktree_path
      )

      raise "Failed to list changed files: #{stderr.presence || stdout}" unless status.success?

      stdout.lines.map(&:strip).reject(&:blank?)
    end

    def markdown_or_instruction_file?(path)
      planning_doc_file?(path) || INSTRUCTION_FILES.include?(path)
    end

    def planning_doc_file?(path)
      path == "docs/high-level-design.md" || path.start_with?("docs/intent/")
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
