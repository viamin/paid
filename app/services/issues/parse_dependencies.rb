# frozen_string_literal: true

module Issues
  # Parses an issue's body text and comments to extract dependency references
  # to other issues within the same project, then persists those relationships
  # as IssueDependency records.
  #
  # Handles common formats:
  #   - "## Dependencies\n- #101\n- #102"
  #   - "Depends on #101, #102"
  #   - "Depends on: #101"
  #   - "Blocked by #101"
  #   - Checklist items: "- [ ] #101"
  #
  # Comments support the same addition patterns plus removal patterns:
  #   - "No longer depends on #101"
  #   - "No longer blocked by #101"
  #   - "Unblocked by #101"
  #   - "Remove dependency #101"
  #
  # Comment-declared dependencies are additive to body-declared ones.
  # Comments are processed chronologically — the latest directive wins:
  #   - Within a single comment, removals take precedence over additions.
  #   - Across comments, a later "Depends on #N" re-adds a previously removed
  #     dep, and a later "No longer depends on #N" removes it again.
  #
  # The final dependency set is NOT simply (body + comments) - removals;
  # it is the result of replaying all directives in order.
  #
  # @example
  #   Issues::ParseDependencies.call(issue: issue, comments: ["Depends on #101"])
  class ParseDependencies
    DEPENDENCY_SECTION_PATTERN = /
      ^\#+\s*Dependenc(?:y|ies)\b[^\n]*\n  # Header line (## Dependencies, etc.)
      ([\s\S]*?)                           # Section body (non-greedy, up to next heading)
      (?=^\#|\z)                           # Lookahead for next heading or end
    /xim

    INLINE_DEPENDS_PATTERN = /
      \b(?:depends?\s+on|blocked?\s+by)\b   # Keyword
      :?\s*                                 # Optional colon
      ((?:\#\d+[\s,]*)+)                    # One or more #N references
    /xi

    INLINE_REMOVAL_PATTERN = /
      \b(?:
        no\s+longer\s+(?:depends?\s+on|blocked?\s+by)\b # "no longer depends on"
        |unblocked?\s+by\b                              # "unblocked by"
        |remove\s+dependenc(?:y|ies)\b(?:\s+on\b)?      # "remove dependency [on]"
      )
      :?\s*                                             # Optional colon
      ((?:\#\d+[\s,]*)+)                                # One or more #N references
    /xi

    ISSUE_REF_PATTERN = /\#(\d+)/

    attr_reader :issue, :adjacency, :comments

    def initialize(issue:, adjacency: nil, comments: [])
      @issue = issue
      @adjacency = adjacency
      @comments = comments || []
    end

    def self.call(...)
      new(...).call
    end

    def call
      referenced_numbers = resolve_dependencies.to_a

      current_dep_ids = issue.issue_dependencies.pluck(:depends_on_issue_id).to_set
      return if referenced_numbers.empty? && current_dep_ids.empty?

      new_dep_ids = Set.new

      if referenced_numbers.any?
        project_issues = issue.project.issues
          .where(github_number: referenced_numbers, is_pull_request: false)
          .index_by(&:github_number)

        adj = adjacency || IssueDependency.project_adjacency(issue.project)

        referenced_numbers.each do |number|
          dep_issue = project_issues[number]
          next unless dep_issue
          next if dep_issue.id == issue.id

          new_dep_ids << dep_issue.id

          next if current_dep_ids.include?(dep_issue.id)
          next if would_create_cycle?(dep_issue, adj)

          issue.issue_dependencies.create!(depends_on_issue: dep_issue)
        end
      end

      stale_ids = current_dep_ids - new_dep_ids
      issue.issue_dependencies.where(depends_on_issue_id: stale_ids).delete_all if stale_ids.any?
    end

    private

    def extract_dependency_numbers(text)
      numbers = Set.new

      extract_from_dependency_section(text, numbers)
      extract_from_inline_patterns(text, numbers)

      numbers.to_a
    end

    def extract_from_dependency_section(text, numbers)
      text.scan(DEPENDENCY_SECTION_PATTERN) do |section_body|
        section_body[0].scan(ISSUE_REF_PATTERN) { |match| numbers << match[0].to_i }
      end
    end

    def extract_from_inline_patterns(text, numbers)
      text.scan(INLINE_DEPENDS_PATTERN) do |refs|
        refs[0].scan(ISSUE_REF_PATTERN) { |match| numbers << match[0].to_i }
      end
    end

    # Processes body then comments chronologically. Within a single comment,
    # removals take precedence over additions. Across comments, a later
    # directive can override an earlier one (e.g., re-add after removal).
    def resolve_dependencies
      dep_numbers = Set.new
      dep_numbers.merge(extract_dependency_numbers(issue.body)) if issue.body.present?

      comments.each do |comment_body|
        next if comment_body.blank?

        added = Set.new(extract_dependency_numbers(comment_body))
        removed = Set.new
        extract_removal_numbers(comment_body, removed)

        # Within a single comment, removals win over additions
        added.subtract(removed)

        dep_numbers.merge(added)
        dep_numbers.subtract(removed)
      end

      dep_numbers
    end

    def extract_removal_numbers(text, numbers)
      text.scan(INLINE_REMOVAL_PATTERN) do |refs|
        refs[0].scan(ISSUE_REF_PATTERN) { |match| numbers << match[0].to_i }
      end
    end

    def would_create_cycle?(dep_issue, adjacency)
      Issues::DetectCycle.call(from_issue: dep_issue, target_issue_id: issue.id, adjacency: adjacency)
    end
  end
end
