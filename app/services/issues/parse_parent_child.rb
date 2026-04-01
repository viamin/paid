# frozen_string_literal: true

module Issues
  # Parses an issue's body text and comments to extract parent-child
  # relationships, then persists them by setting parent_issue_id on
  # child issues.
  #
  # Supports two directions:
  #
  # 1. **Parent listing children** (body sections):
  #      ## Child Issues
  #      - [ ] #101
  #      - [ ] #102
  #
  #    Recognized headings: "Child Issues", "Sub-issues", "Sub Issues",
  #    "Subtasks", "Sub-tasks", "Sub Tasks" (any heading level).
  #
  # 2. **Child declaring parent** (inline, body + comments):
  #      Part of #50
  #      Sub-issue of #50
  #      Child of #50
  #
  # Comments support the same patterns plus removal:
  #      No longer part of #50
  #      No longer child of #50
  #
  # Comments are processed chronologically — the latest directive wins,
  # matching ParseDependencies semantics.
  #
  # @param issue [Issue] the issue to parse parent-child relationships for
  # @param comments [Array<String>] comment bodies, pre-sorted oldest-first
  class ParseParentChild
    # Section heading that introduces a list of child issues. Captures
    # the heading level (number of #s) so we stop at the next heading
    # of equal or higher level, allowing sub-headings within the section.
    CHILD_SECTION_HEADING = /^(\#+)\s*(?:child\s+issues?|sub[- ]?issues?|sub[- ]?tasks?)\b/im

    # Inline pattern where an issue declares itself as a child of another.
    PARENT_DECLARATION_PATTERN = /
      \b(?:part|child|sub[- ]?issue|sub[- ]?task)\s+of\b
      :?\s*
      \#(\d+)
    /xi

    # Comment pattern to remove a parent declaration.
    PARENT_REMOVAL_PATTERN = /
      \bno\s+longer\s+(?:part|child|sub[- ]?issue|sub[- ]?task)\s+of\b
      :?\s*
      \#(\d+)
    /xi

    ISSUE_REF_PATTERN = /#(\d+)/

    attr_reader :issue, :comments

    def initialize(issue:, comments: [])
      @issue = issue
      @comments = comments || []
    end

    def self.call(...)
      new(...).call
    end

    # Returns true if sync_children made changes via update_all (which
    # bypasses callbacks and needs a manual broadcast). sync_parent uses
    # update! which triggers after_update_commit broadcasts on its own.
    def call
      child_numbers = resolve_child_numbers
      parent_number, parent_declared = resolve_parent_number

      children_changed = sync_children(child_numbers)
      sync_parent(parent_number, parent_declared)
      children_changed
    end

    private

    # Resolves the set of child issue numbers declared by this issue's
    # body and comments. Both body and comments are scanned for
    # child-listing sections (e.g. "## Child Issues"); all matching
    # sections are merged into a single set.
    def resolve_child_numbers
      children = Set.new

      children.merge(extract_child_section_refs(issue.body)) if issue.body.present?

      comments.each do |comment_body|
        next if comment_body.blank?
        children.merge(extract_child_section_refs(comment_body))
      end

      children.delete(issue.github_number)
      children
    end

    # Resolves the parent issue number for this issue from inline
    # declarations in body and comments. Comments are replayed
    # chronologically — the latest directive wins.
    #
    # Returns [parent_number, declared] where +declared+ is true if any
    # parent declaration was found (even if later removed). This lets
    # sync_parent distinguish "no parent mentioned" (leave as-is) from
    # "parent was declared then removed" (clear it).
    def resolve_parent_number
      parent = nil
      declared = false

      if issue.body.present?
        match = issue.body.match(PARENT_DECLARATION_PATTERN)
        if match
          parent = match[1].to_i
          declared = true
        end
      end

      comments.each do |comment_body|
        next if comment_body.blank?

        # Process removals first so "No longer part of #N" doesn't also
        # match the addition pattern and overwrite an unrelated parent.
        # Only mark declared when the removal targets the currently tracked
        # parent — a removal for a *different* number shouldn't clear a
        # parent set by another mechanism (e.g. parent-listing).
        if (removal = comment_body.match(PARENT_REMOVAL_PATTERN))
          if parent == removal[1].to_i
            parent = nil
            declared = true
          end
        end

        # Strip removal phrases before checking for additions, since
        # "No longer part of #123" contains "part of #123".
        stripped = comment_body.gsub(PARENT_REMOVAL_PATTERN, "")
        if (addition = stripped.match(PARENT_DECLARATION_PATTERN))
          parent = addition[1].to_i
          declared = true
        end
      end

      parent = nil if parent == issue.github_number
      [ parent, declared ]
    end

    # Extracts #NNN references from all child-issues sections in the
    # text. Each section extends from its heading until the next heading
    # of equal or higher level (fewer or equal # characters), allowing
    # sub-headings (###) within a ## section. Multiple matching sections
    # (e.g. both "## Child Issues" and "## Subtasks") are all parsed.
    def extract_child_section_refs(text)
      refs = []
      search_from = 0

      while (match = text.match(CHILD_SECTION_HEADING, search_from))
        heading_level = match[1].length
        rest = text[match.end(0)..]

        # Stop at the next heading of same or higher level.
        # A heading of level N has exactly N '#' characters followed by
        # whitespace, NOT followed by another '#'. Require \s+ (not \s*)
        # so bare issue refs like "#123" on their own line don't match.
        stop_pattern = /^\#{1,#{heading_level}}(?!\#)\s+/m
        next_heading = rest.match(stop_pattern)
        section = next_heading ? rest[0...next_heading.begin(0)] : rest

        refs.concat(section.scan(ISSUE_REF_PATTERN).flatten.map(&:to_i))
        search_from = match.end(0) + (next_heading ? next_heading.begin(0) : section.length)
      end

      refs.uniq
    end

    # Updates parent_issue_id on child issues. Clears stale children
    # that were previously parented to this issue but are no longer
    # in the list. Only affects non-PR issues to avoid interfering
    # with PR-to-issue linking. Returns true if any rows changed.
    def sync_children(child_numbers)
      project = issue.project
      existing_children = project.issues.where(parent_issue_id: issue.id, is_pull_request: false)

      if child_numbers.empty?
        return existing_children.update_all(parent_issue_id: nil, updated_at: Time.current) > 0
      end

      child_issues = project.issues.where(
        github_number: child_numbers.to_a,
        is_pull_request: false
      )

      new_child_ids = child_issues.pluck(:id).to_set
      changed = 0

      # Set parent only on children that don't already have the correct value.
      # where.not excludes NULLs in Rails 8, so explicitly include them.
      changed += child_issues
        .where(parent_issue_id: [ nil ]).or(child_issues.where.not(parent_issue_id: issue.id))
        .update_all(parent_issue_id: issue.id, updated_at: Time.current)

      # Clear parent on issues removed from the list
      changed += existing_children
        .where.not(id: new_child_ids)
        .update_all(parent_issue_id: nil, updated_at: Time.current)

      changed > 0
    end

    # Sets or clears parent_issue_id on this issue based on inline
    # declarations. Only acts when a parent declaration was found in the
    # body or comments (+declared+ is true) to avoid clearing parent_issue_id
    # that was set by other mechanisms (e.g. PR linking). Returns true if
    # a change was persisted.
    def sync_parent(parent_number, declared)
      return false unless declared

      if parent_number.nil?
        return false unless issue.parent_issue_id.present?
        issue.update!(parent_issue_id: nil)
        return true
      end

      parent = issue.project.issues.find_by(
        github_number: parent_number,
        is_pull_request: false
      )
      return false unless parent
      return false if issue.parent_issue_id == parent.id

      issue.update!(parent_issue_id: parent.id)
      true
    end
  end
end
