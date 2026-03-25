# frozen_string_literal: true

module Issues
  # Parses an issue's body text and comments to extract dependency references
  # to other issues, including cross-project references, then persists those
  # relationships as IssueDependency records.
  #
  # Handles common formats:
  #   - "## Dependencies\n- #101\n- #102"
  #   - "Depends on #101, #102"
  #   - "Depends on: #101"
  #   - "Blocked by #101"
  #   - "Depends on viamin/agent-harness#31"
  #   - "Blocked by viamin/other-project#42"
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
  # @param issue [Issue] the issue to parse dependencies for
  # @param adjacency [Hash] optional pre-computed adjacency map for cycle detection
  # @param comments [Array<String>] comment bodies, pre-sorted oldest-first.
  #   Order matters because directives are replayed chronologically.
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
      ((?:(?:[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+)?\#\d+[\s,]*)+)  # One or more refs
    /xi

    INLINE_REMOVAL_PATTERN = /
      \b(?:
        no\s+longer\s+(?:depends?\s+on|blocked?\s+by)\b # "no longer depends on"
        |unblocked\s+by\b                               # "unblocked by"
        |remove\s+dependenc(?:y|ies)\b(?:\s+on\b)?      # "remove dependency [on]"
      )
      :?\s*                                             # Optional colon
      ((?:\#\d+[\s,]*)+)                                # One or more #N references
    /xi

    # Matches cross-repo references like owner/repo#123
    # Uses [1-9]\d* to reject #0 — GitHub issues start at 1 and the DB
    # CHECK constraint requires depends_on_number > 0.
    CROSS_REPO_REF_PATTERN = /([a-zA-Z0-9._-]+)\/([a-zA-Z0-9._-]+)\#([1-9]\d*)/

    # Matches same-project references like #123
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
      local_numbers, cross_refs = resolve_dependencies

      current_deps = issue.issue_dependencies.to_a
      current_local_ids = current_deps.select(&:local?).map(&:depends_on_issue_id).to_set
      current_external_keys = current_deps.select(&:external?).map { |d|
        [ d.depends_on_owner.downcase, d.depends_on_repo.downcase, d.depends_on_number ]
      }.to_set

      return if local_numbers.empty? && cross_refs.empty? &&
               current_local_ids.empty? && current_external_keys.empty?

      new_local_ids = sync_local_deps(local_numbers, current_local_ids)
      new_cross_refs = sync_cross_project_deps(cross_refs, current_local_ids | new_local_ids, current_external_keys)

      remove_stale_local_deps(current_local_ids, new_local_ids | new_cross_refs[:resolved_ids])
      remove_stale_external_deps(current_external_keys, new_cross_refs[:external_keys])
    end

    private

    # Processes body then comments in the order given. Within a single comment,
    # removals take precedence over additions. Across comments, a later
    # directive can override an earlier one (e.g., re-add after removal).
    # Callers must supply comments sorted oldest-first for correct semantics.
    def resolve_dependencies
      local_numbers = Set.new
      cross_refs = Set.new

      if issue.body.present?
        extract_body_refs(issue.body, local_numbers, cross_refs)
      end

      comments.each do |comment_body|
        next if comment_body.blank?

        added_local = Set.new
        added_cross = Set.new
        extract_body_refs(comment_body, added_local, added_cross)

        removed = Set.new
        extract_removal_numbers(comment_body, removed)

        # Within a single comment, removals win over additions.
        # Removals only apply to local #N refs; cross-project removal
        # patterns (owner/repo#N) are not supported by INLINE_REMOVAL_PATTERN.
        added_local.subtract(removed)

        local_numbers.merge(added_local)
        cross_refs.merge(added_cross)
        local_numbers.subtract(removed)
      end

      [ local_numbers.to_a, cross_refs.to_a ]
    end

    # INLINE_REMOVAL_PATTERN has a single capture group, so scan yields
    # one-element arrays. Parenthesized destructuring |(refs_str)| extracts
    # the captured String directly — without it, refs_str would be an Array.
    def extract_removal_numbers(text, numbers)
      text.scan(INLINE_REMOVAL_PATTERN) do |(refs_str)|
        refs_str.scan(ISSUE_REF_PATTERN) { |(num)| numbers << num.to_i }
      end
    end

    # Extracts refs from body using both dependency sections and inline patterns.
    # Only dependency-scoped text is parsed — incidental #N mentions (e.g. in a
    # "Notes" section) are intentionally ignored.
    def extract_body_refs(body, local_numbers, cross_refs)
      body.scan(DEPENDENCY_SECTION_PATTERN) do |(section_body)|
        extract_all_refs(section_body, local_numbers, cross_refs)
      end

      extract_inline_refs(body, local_numbers, cross_refs)
    end

    # Extracts refs from inline "Depends on" / "Blocked by" patterns only.
    def extract_inline_refs(text, local_numbers, cross_refs)
      text.scan(INLINE_DEPENDS_PATTERN) do |(refs_str)|
        extract_all_refs(refs_str, local_numbers, cross_refs)
      end
    end

    # Extracts both cross-repo and local issue refs from a string of refs.
    def extract_all_refs(text, local_numbers, cross_refs)
      text.scan(CROSS_REPO_REF_PATTERN) do |owner, repo, number|
        cross_refs << [ owner, repo, number.to_i ]
      end

      stripped = text.gsub(CROSS_REPO_REF_PATTERN, "")
      stripped.scan(ISSUE_REF_PATTERN) { |(num)| local_numbers << num.to_i }
    end

    def sync_local_deps(referenced_numbers, current_local_ids)
      new_local_ids = Set.new
      return new_local_ids if referenced_numbers.empty?

      project_issues = issue.project.issues
        .where(github_number: referenced_numbers, is_pull_request: false)
        .index_by(&:github_number)

      adj = adjacency || IssueDependency.account_adjacency(issue.project.account)

      referenced_numbers.each do |number|
        dep_issue = project_issues[number]
        next unless dep_issue
        next if dep_issue.id == issue.id

        new_local_ids << dep_issue.id

        next if current_local_ids.include?(dep_issue.id)
        next if would_create_cycle?(dep_issue, adj)

        issue.issue_dependencies.create!(depends_on_issue: dep_issue)
      end

      new_local_ids
    end

    def sync_cross_project_deps(cross_refs, current_local_ids, current_external_keys)
      resolved_ids = Set.new
      external_keys = Set.new
      return { resolved_ids: resolved_ids, external_keys: external_keys } if cross_refs.empty?

      account = issue.project.account
      adj = adjacency || IssueDependency.account_adjacency(account)

      project_lookup = build_project_lookup(account, cross_refs)
      issues_by_project = build_issue_lookup(project_lookup, cross_refs)

      cross_refs.each do |owner, repo, number|
        project_key = [ owner.downcase, repo.downcase ]
        project = project_lookup[project_key]

        if project
          dep_issue = issues_by_project.dig(project.id, number)

          if dep_issue
            resolved_ids << dep_issue.id
            next if current_local_ids.include?(dep_issue.id)
            next if would_create_cycle?(dep_issue, adj)

            issue.issue_dependencies.create!(depends_on_issue: dep_issue)
            next
          end
        end

        # Store as external reference with normalized (downcased) owner/repo
        key = [ owner.downcase, repo.downcase, number ]
        external_keys << key
        next if current_external_keys.include?(key)

        issue.issue_dependencies.create!(
          depends_on_owner: owner.downcase,
          depends_on_repo: repo.downcase,
          depends_on_number: number
        )
      end

      { resolved_ids: resolved_ids, external_keys: external_keys }
    end

    # Batch-loads projects for all unique owner/repo pairs in cross_refs
    def build_project_lookup(account, cross_refs)
      lookup = {}
      self_key = [ issue.project.owner.downcase, issue.project.repo.downcase ]
      lookup[self_key] = issue.project

      other_pairs = cross_refs
        .map { |owner, repo, _| [ owner.downcase, repo.downcase ] }
        .uniq
        .reject { |pair| pair == self_key }

      if other_pairs.any?
        conditions = other_pairs.map { "(LOWER(owner) = ? AND LOWER(repo) = ?)" }.join(" OR ")
        values = other_pairs.flatten
        account.projects.where(conditions, *values).each do |project|
          lookup[[ project.owner.downcase, project.repo.downcase ]] = project
        end
      end

      lookup
    end

    # Batch-loads issues for all resolved projects and referenced numbers
    def build_issue_lookup(project_lookup, cross_refs)
      refs_by_project_id = Hash.new { |h, k| h[k] = Set.new }

      cross_refs.each do |owner, repo, number|
        project = project_lookup[[ owner.downcase, repo.downcase ]]
        refs_by_project_id[project.id] << number if project
      end

      result = {}
      refs_by_project_id.each do |project_id, numbers|
        issues = Issue.where(project_id: project_id, github_number: numbers.to_a, is_pull_request: false)
        result[project_id] = issues.index_by(&:github_number)
      end
      result
    end

    def remove_stale_local_deps(current_local_ids, new_local_ids)
      stale_ids = current_local_ids - new_local_ids
      return unless stale_ids.any?

      issue.issue_dependencies.where(depends_on_issue_id: stale_ids).delete_all
    end

    def remove_stale_external_deps(current_external_keys, new_external_keys)
      stale_keys = current_external_keys - new_external_keys
      return if stale_keys.empty?

      deps_table = IssueDependency.arel_table
      combined = stale_keys.map do |owner, repo, number|
        deps_table[:depends_on_owner].eq(owner)
          .and(deps_table[:depends_on_repo].eq(repo))
          .and(deps_table[:depends_on_number].eq(number))
      end.reduce(:or)

      issue.issue_dependencies.where(combined).delete_all
    end

    def would_create_cycle?(dep_issue, adjacency)
      Issues::DetectCycle.call(from_issue: dep_issue, target_issue_id: issue.id, adjacency: adjacency)
    end
  end
end
