# frozen_string_literal: true

module Issues
  # Parses an issue's body text to extract dependency references to other issues,
  # including cross-project references, then persists those relationships as
  # IssueDependency records.
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
  # @example
  #   Issues::ParseDependencies.call(issue: issue)
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

    # Matches cross-repo references like owner/repo#123
    # Uses [1-9]\d* to reject #0 — GitHub issues start at 1 and the DB
    # CHECK constraint requires depends_on_number > 0.
    CROSS_REPO_REF_PATTERN = /([a-zA-Z0-9._-]+)\/([a-zA-Z0-9._-]+)\#([1-9]\d*)/

    # Matches same-project references like #123
    ISSUE_REF_PATTERN = /\#(\d+)/

    attr_reader :issue, :adjacency

    def initialize(issue:, adjacency: nil)
      @issue = issue
      @adjacency = adjacency
    end

    def self.call(...)
      new(...).call
    end

    def call
      if issue.body.present?
        local_numbers, cross_refs = extract_all_refs
      else
        local_numbers = []
        cross_refs = []
      end

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

    def extract_all_refs
      local_numbers = Set.new
      cross_refs = Set.new

      extract_from_dependency_section(local_numbers, cross_refs)
      extract_from_inline_patterns(local_numbers, cross_refs)

      [ local_numbers.to_a, cross_refs.to_a ]
    end

    def extract_from_dependency_section(local_numbers, cross_refs)
      issue.body.scan(DEPENDENCY_SECTION_PATTERN) do |section_body|
        extract_refs_from_text(section_body[0], local_numbers, cross_refs)
      end
    end

    def extract_from_inline_patterns(local_numbers, cross_refs)
      issue.body.scan(INLINE_DEPENDS_PATTERN) do |refs|
        extract_refs_from_text(refs[0], local_numbers, cross_refs)
      end
    end

    def extract_refs_from_text(text, local_numbers, cross_refs)
      # Extract cross-repo refs first
      text.scan(CROSS_REPO_REF_PATTERN) do |owner, repo, number|
        cross_refs << [ owner, repo, number.to_i ]
      end

      # Extract same-project refs (strip cross-repo refs first to avoid double-matching)
      stripped = text.gsub(CROSS_REPO_REF_PATTERN, "")
      stripped.scan(/\#(\d+)/) { |match| local_numbers << match[0].to_i }
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
