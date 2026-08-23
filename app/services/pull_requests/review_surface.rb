# frozen_string_literal: true

require "open3"

module PullRequests
  # @spec TDD-PR-002
  # @spec TDD-PR-003
  # @spec TDD-PR-004
  # @spec TDD-PR-005
  class ReviewSurface
    LID_REPORT_HEADING = "## LID Phase Report"
    TEST_OUTLINE_HEADING = "## Test Outline"
    SPEC_TAG = "@ spec".delete(" ")
    SPEC_ID_PATTERN = /([A-Z0-9-]+-\d+)/
    TEST_FILE_PATTERN = /\A(spec|test|\.ephemeral-tests)\//.freeze
    LID_DOC_PATTERN = %r{\A(?:docs/high-level-design\.md|docs/arrows/index\.yaml|docs/intent/|AGENTS\.md|CLAUDE\.md|\.github/copilot-instructions\.md)}.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(body:, agent_run:)
      @body = body.to_s
      @agent_run = agent_run
    end

    def call
      updated = update_test_outline_section(body)
      replace_or_remove_section(updated, LID_REPORT_HEADING, lid_phase_report_section)
    end

    private

    attr_reader :body, :agent_run

    # Only rewrite the Test Outline section when this run's own diff touched
    # test files. Follow-up runs (test_fixing/refactor) that don't touch test
    # files would otherwise recompute an empty outline from their own diff
    # and delete the section that earlier red-phase commits populated.
    def update_test_outline_section(markdown)
      return markdown if changed_test_files.empty?

      replace_or_remove_section(markdown, TEST_OUTLINE_HEADING, test_outline_section)
    end

    def test_outline_section
      outlines = changed_test_files.filter_map { |path| outline_for(path) }
      return if outlines.empty?

      [
        TEST_OUTLINE_HEADING,
        "",
        "```text",
        outlines.join("\n\n"),
        "```"
      ].join("\n")
    end

    def outline_for(path)
      full_path = full_worktree_path(path)
      return if full_path.blank? || !File.exist?(full_path)

      lines = outline_lines(File.read(full_path), path: path)
      return if lines.empty?

      lines.join("\n")
    rescue StandardError
      nil
    end

    def outline_lines(content, path:)
      lines = []
      stack = []
      file_root_emitted = false

      content.each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        indent = line[/\A\s*/].to_s.length

        if (suite_title = suite_title_for(stripped))
          stack.pop while stack.any? && stack.last[:indent] >= indent
          lines << "#{"  " * stack.length}#{suite_title}"
          stack << { indent: indent, title: suite_title }
          next
        end

        next unless (example_title = example_title_for(stripped))

        stack.pop while stack.any? && stack.last[:indent] >= indent
        if stack.empty?
          unless file_root_emitted
            lines << File.basename(path)
            file_root_emitted = true
          end
          lines << "  #{example_title}"
        else
          lines << "#{"  " * stack.length}#{example_title}"
        end
      end

      lines
    end

    def suite_title_for(stripped)
      rspec_suite_title(stripped) || generic_suite_title(stripped)
    end

    def rspec_suite_title(stripped)
      match = stripped.match(/\A(?:RSpec\.)?(?:describe|context|feature)\s+(.+?)(?:\s+do|\s*\{)\s*\z/)
      normalize_title_argument(match[1]) if match
    end

    def generic_suite_title(stripped)
      ruby_match = stripped.match(/\Aclass\s+([A-Z][\w:]*)(?:\s*<\s*[\w:]+)?\s*\z/)
      return ruby_match[1] if ruby_match

      python_match = stripped.match(/\Aclass\s+([A-Z][\w]*)(?:\([^)]*\))?:\s*\z/)
      python_match[1] if python_match
    end

    def example_title_for(stripped)
      rspec_example_title(stripped) ||
        minitest_macro_title(stripped) ||
        test_method_title(stripped)
    end

    def rspec_example_title(stripped)
      match = stripped.match(/\A(?:it|specify|example|scenario)\s+(.+?)(?:\s+do|\s*\{)\s*\z/)
      normalize_title_argument(match[1]) if match
    end

    def minitest_macro_title(stripped)
      match = stripped.match(/\Atest\s+(.+?)(?:\s+do|\s*\{)\s*\z/)
      normalize_title_argument(match[1]) if match
    end

    def test_method_title(stripped)
      match = stripped.match(/\Adef\s+(test_[\w!?]+)\s*(?:\(.*\))?\s*(?::|\z)/)
      return unless match

      match[1].sub(/\Atest_/, "").tr("_", " ")
    end

    def normalize_title_argument(argument)
      cleaned = argument.to_s.strip.sub(/\A\((.*)\)\z/, '\1')
      quoted = cleaned.match(/\A["'](.+?)["'](?:,.*)?\z/)
      return quoted[1] if quoted

      cleaned.sub(/,.*\z/, "").strip
    end

    def lid_phase_report_section
      return unless lid_mode_for(agent_run.project).present?

      [
        LID_REPORT_HEADING,
        "",
        "- Mode: `#{lid_mode_for(agent_run.project)}`",
        "- Specs touched: #{specs_touched_summary}",
        "- Tests-first evidence: #{tests_first_summary}",
        "- Coherence check: #{coherence_check_summary}"
      ].join("\n")
    end

    def lid_mode_for(project)
      return unless project.respond_to?(:lid_mode)

      project.lid_mode.to_s.strip.downcase.presence
    end

    def specs_touched_summary
      spec_ids = spec_ids_for_report
      touched_docs = touched_lid_docs

      details = []
      details << "EARS IDs: #{spec_ids.join(', ')}" if spec_ids.any?
      details << "LID docs: #{touched_docs.join(', ')}" if touched_docs.any?

      details.presence&.join("; ") || "No LID spec IDs or intent doc edits were detected automatically."
    end

    def tests_first_summary
      return "Changed test files: #{changed_test_files.join(', ')}." if changed_test_files.any?

      spec_ids = spec_ids_for_report
      return "@spec annotations detected for #{spec_ids.join(', ')}." if spec_ids.any?

      "No test-file changes or @spec annotations were detected automatically."
    end

    def coherence_check_summary
      line = latest_coherence_check_line
      return "Not found in captured agent output." unless line
      return "Reported success in agent output." if line.match?(/pass(?:ed)?|success|0 failures/i)
      return "Reported failures in agent output; inspect the run logs." if line.match?(/fail(?:ed|ures?)?/i)

      "Referenced in agent output; inspect the run logs for the full result."
    end

    def latest_coherence_check_line
      coherence_log = latest_coherence_log
      return unless coherence_log

      coherence_log.lines.reverse_each.find do |line|
        line.match?(/coherence-check\.mjs|\/opt\/paid-lid\/bin\/coherence-check\.mjs/)
      end
    end

    def latest_coherence_log
      agent_run.agent_run_logs
        .where(log_type: %w[stdout stderr])
        .where("content LIKE :default_path OR content LIKE :vendored_path",
          default_path: "%coherence-check.mjs%",
          vendored_path: "%/opt/paid-lid/bin/coherence-check.mjs%")
        .order(created_at: :desc, id: :desc)
        .pick(:content)
    end

    def agent_output
      agent_run.agent_run_logs
        .where(log_type: %w[stdout stderr])
        .order(created_at: :desc, id: :desc)
        .limit(200)
        .pluck(:content)
        .reverse
        .join("\n")
    end

    def changed_test_files
      changed_files.grep(TEST_FILE_PATTERN)
    end

    def touched_lid_docs
      changed_files.grep(LID_DOC_PATTERN)
    end

    def spec_ids_for_report
      (spec_ids_from_diff + spec_ids_from_output).uniq
    end

    def spec_ids_from_diff
      git_diff.scan(spec_annotation_pattern).flatten.uniq
    end

    def spec_ids_from_output
      agent_output.scan(spec_annotation_pattern).flatten.uniq
    rescue StandardError
      []
    end

    def spec_annotation_pattern
      @spec_annotation_pattern ||= Regexp.new("#{Regexp.escape(SPEC_TAG)}\\s+#{SPEC_ID_PATTERN.source}")
    end

    def changed_files
      @changed_files ||= git_diff_name_only.lines.map(&:strip).reject(&:empty?)
    end

    def git_diff
      @git_diff ||= run_git_diff("--unified=0")
    end

    def git_diff_name_only
      @git_diff_name_only ||= run_git_diff("--name-only")
    end

    def run_git_diff(*args)
      return "" if agent_run.worktree_path.blank? || agent_run.base_commit_sha.blank? || agent_run.result_commit_sha.blank?

      stdout, status = Open3.capture2(
        "git",
        "-C",
        agent_run.worktree_path,
        "diff",
        *args,
        agent_run.base_commit_sha,
        agent_run.result_commit_sha
      )
      status.success? ? stdout : ""
    rescue StandardError
      ""
    end

    def full_worktree_path(path)
      return if agent_run.worktree_path.blank?

      File.join(agent_run.worktree_path, path)
    end

    def replace_or_remove_section(markdown, heading, section)
      pattern = /^#{Regexp.escape(heading)}\n.*?(?=^##\s|\z)/m
      without_section = markdown.to_s.sub(pattern, "").strip
      return without_section if section.blank?
      return markdown.sub(pattern, section) if markdown.match?(pattern)
      return section if without_section.blank?

      "#{without_section}\n\n#{section}"
    end
  end
end
