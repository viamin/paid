# frozen_string_literal: true

module Issues
  # Parses an issue's body text to extract dependency references to other issues
  # within the same project, then persists those relationships as IssueDependency
  # records.
  #
  # Handles common formats:
  #   - "## Dependencies\n- #101\n- #102"
  #   - "Depends on #101, #102"
  #   - "Depends on: #101"
  #   - "Blocked by #101"
  #   - Checklist items: "- [ ] #101"
  #
  # @example
  #   Issues::ParseDependencies.call(issue: issue)
  class ParseDependencies
    DEPENDENCY_SECTION_PATTERN = /
      ^\#*\s*Dependenc(?:y|ies)\b[^\n]*\n  # Header line (## Dependencies, etc.)
      ((?:[\s\S](?!\n\#))*?)               # Section body (stop at next heading)
      (?=\n\#|\z)                           # Lookahead for next heading or end
    /xi

    INLINE_DEPENDS_PATTERN = /
      \b(?:depends?\s+on|blocked?\s+by)\b   # Keyword
      :?\s*                                 # Optional colon
      ((?:\#\d+[\s,]*)+)                    # One or more #N references
    /xi

    ISSUE_REF_PATTERN = /\#(\d+)/

    attr_reader :issue

    def initialize(issue:)
      @issue = issue
    end

    def self.call(...)
      new(...).call
    end

    def call
      return if issue.body.blank?

      referenced_numbers = extract_dependency_numbers
      return if referenced_numbers.empty?

      project_issues = issue.project.issues
        .where(github_number: referenced_numbers, is_pull_request: false)
        .index_by(&:github_number)

      current_dep_ids = issue.issue_dependencies.pluck(:depends_on_issue_id).to_set
      new_dep_ids = Set.new

      referenced_numbers.each do |number|
        dep_issue = project_issues[number]
        next unless dep_issue
        next if dep_issue.id == issue.id

        new_dep_ids << dep_issue.id

        next if current_dep_ids.include?(dep_issue.id)
        next if would_create_cycle?(dep_issue)

        issue.issue_dependencies.create(depends_on_issue: dep_issue)
      end

      stale_ids = current_dep_ids - new_dep_ids
      issue.issue_dependencies.where(depends_on_issue_id: stale_ids).delete_all if stale_ids.any?
    end

    private

    def extract_dependency_numbers
      numbers = Set.new

      extract_from_dependency_section(numbers)
      extract_from_inline_patterns(numbers)

      numbers.to_a
    end

    def extract_from_dependency_section(numbers)
      issue.body.scan(DEPENDENCY_SECTION_PATTERN) do |section_body|
        section_body[0].scan(ISSUE_REF_PATTERN) { |match| numbers << match[0].to_i }
      end
    end

    def extract_from_inline_patterns(numbers)
      issue.body.scan(INLINE_DEPENDS_PATTERN) do |refs|
        refs[0].scan(ISSUE_REF_PATTERN) { |match| numbers << match[0].to_i }
      end
    end

    def would_create_cycle?(dep_issue)
      Issues::DetectCycle.call(from_issue: dep_issue, target_issue_id: issue.id)
    end
  end
end
