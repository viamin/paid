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
    CROSS_REPO_REF_PATTERN = /([a-zA-Z0-9._-]+)\/([a-zA-Z0-9._-]+)\#(\d+)/

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
        [ d.depends_on_owner, d.depends_on_repo, d.depends_on_number ]
      }.to_set

      return if local_numbers.empty? && cross_refs.empty? &&
               current_local_ids.empty? && current_external_keys.empty?

      new_local_ids = sync_local_deps(local_numbers, current_local_ids)
      new_cross_refs = sync_cross_project_deps(cross_refs, current_local_ids, current_external_keys)

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
      adj = adjacency || IssueDependency.account_adjacency(issue.project.account)

      cross_refs.each do |owner, repo, number|
        # Resolve self-project references as local deps instead of dropping them
        project =
          if owner == issue.project.owner && repo == issue.project.repo
            issue.project
          else
            account.projects.find_by(owner: owner, repo: repo)
          end

        if project
          dep_issue = project.issues.find_by(github_number: number, is_pull_request: false)

          if dep_issue
            resolved_ids << dep_issue.id
            next if current_local_ids.include?(dep_issue.id)
            next if would_create_cycle?(dep_issue, adj)

            issue.issue_dependencies.create!(depends_on_issue: dep_issue)
            next
          end
        end

        # Store as external reference
        key = [ owner, repo, number ]
        external_keys << key
        next if current_external_keys.include?(key)

        issue.issue_dependencies.create!(
          depends_on_owner: owner,
          depends_on_repo: repo,
          depends_on_number: number
        )
      end

      { resolved_ids: resolved_ids, external_keys: external_keys }
    end

    def remove_stale_local_deps(current_local_ids, new_local_ids)
      stale_ids = current_local_ids - new_local_ids
      return unless stale_ids.any?

      issue.issue_dependencies.where(depends_on_issue_id: stale_ids).delete_all
    end

    def remove_stale_external_deps(current_external_keys, new_external_keys)
      stale_keys = current_external_keys - new_external_keys
      stale_keys.each do |owner, repo, number|
        issue.issue_dependencies.where(
          depends_on_owner: owner,
          depends_on_repo: repo,
          depends_on_number: number
        ).delete_all
      end
    end

    def would_create_cycle?(dep_issue, adjacency)
      Issues::DetectCycle.call(from_issue: dep_issue, target_issue_id: issue.id, adjacency: adjacency)
    end
  end
end
