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
  # Deployment-blocking variants (require the target PR to have been marked
  # deployed before the dependency unblocks; see IssueDependency#deployment_pending?):
  #   - "Awaits deployment of #101"
  #   - "Depends on deployment of #101"
  #   - "Blocked by deployment of viamin/agent-harness#31"
  #   - Within a ## Dependencies section: "- Deployment of #101"
  #
  # Comments support the same addition patterns plus removal patterns.
  # Removals work for both local (#N) and cross-repo (owner/repo#N) refs and
  # remove the dependency entirely (regardless of whether it was
  # deployment-flagged or a plain dependency):
  #   - "No longer depends on #101"
  #   - "No longer awaits deployment of #101"
  #   - "No longer blocked by deployment of viamin/agent-harness#31"
  #   - "Unblocked by #101"
  #   - "Remove dependency #101"
  #   - "Remove deployment dependency on #101"
  #
  # Comment-declared dependency additions are applied on top of the
  # body-declared dependencies, but comment-based removals can remove
  # dependencies introduced either in the body or in earlier comments.
  # Comments are processed chronologically — the latest directive wins:
  #   - Within a single comment, removals take precedence over additions.
  #   - Across comments (relative to the body baseline), a later
  #     "Depends on #N" re-adds a previously removed dep, and a later
  #     "No longer depends on #N" removes it again.
  #
  # When a ref appears with deployment wording anywhere (body or any comment)
  # the resulting dependency is marked as requires_deployment. Removing and
  # re-adding the dep clears and re-derives the flag from later directives.
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
    INLINE_DEPENDS_PATTERN = /
      \b(?:depends?\s+on|blocked?\s+by)\b   # Keyword
      :?\s*                                 # Optional colon
      ((?:(?:[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+)?\#\d+[\s,]*)+)  # One or more refs
    /xi

    # Matches deployment-blocking phrasing: "awaits deployment of #N",
    # "depends on deployment of #N", "blocked by deployment of #N".
    INLINE_DEPLOYMENT_PATTERN = /
      \b(?:
        awaits\s+deployment\s+of
        |(?:depends?\s+on|blocked?\s+by)\s+deployment\s+of
      )\b
      :?\s*
      ((?:(?:[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+)?\#\d+[\s,]*)+)
    /xi

    # Inside a "## Dependencies" section, users commonly write list items as
    # bare phrases like "- Deployment of #101" without a preceding verb.
    SECTION_DEPLOYMENT_PATTERN = /
      \bdeployment\s+of\b
      :?\s*
      ((?:(?:[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+)?\#\d+[\s,]*)+)
    /xi

    INLINE_REMOVAL_PATTERN = /
      \b(?:
        no\s+longer\s+(?:                              # "no longer ..."
          awaits\s+deployment\s+of                     # "no longer awaits deployment of"
          |(?:depends?\s+on|blocked?\s+by)(?:\s+deployment\s+of)?  # "no longer depends on [deployment of]"
        )\b
        |unblocked\s+by\b                              # "unblocked by"
        |remove\s+(?:deployment\s+)?dependenc(?:y|ies)\b(?:\s+on\b)?  # "remove [deployment] dependency [on]"
      )
      :?\s*                                            # Optional colon
      ((?:(?:[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+)?\#\d+[\s,]*)+) # local or cross-repo refs
    /xi

    # Matches phrases that mention issue refs but must NOT be treated as
    # dependencies. Applied in both section-path (before bare-ref extraction)
    # and inline-path (before INLINE_DEPENDS_PATTERN) so that e.g.
    # "Not blocked by #N" is not misread as "blocked by #N".
    NON_DEPENDENCY_PATTERN = /
      \b(?:independent\s+of|not\s+blocked\s+by|no\s+dependency\s+on)\b
      :?\s*
      ((?:(?:[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+)?\#\d+[\s,]*)+)
    /xi

    # Matches cross-repo references like owner/repo#123
    # Uses [1-9]\d* to reject #0 — GitHub issues start at 1 and the DB
    # CHECK constraint requires depends_on_number > 0.
    CROSS_REPO_REF_PATTERN = /([a-zA-Z0-9._-]+)\/([a-zA-Z0-9._-]+)\#([1-9]\d*)/

    # Matches same-project references like #123
    ISSUE_REF_PATTERN = /\#(\d+)/

    DEPENDENCY_HEADING_PATTERN = /\bdependenc(?:y|ies)\b/i
    CHILD_LISTING_HEADING_PATTERN = /\b(?:child\s+issues?|sub[- ]?issues?|sub[- ]?tasks?)\b/i
    MARKDOWN_HEADING_PATTERN = /^[ \t]{0,3}\#{1,6}[ \t]+(.+?)\s*#*\s*$/
    FENCED_CODE_BLOCK_PATTERN = /^[ \t]{0,3}(```|~~~)/

    attr_reader :issue, :adjacency, :comments, :body

    def initialize(issue:, adjacency: nil, comments: [], body: nil)
      @issue = issue
      @adjacency = adjacency
      @comments = comments || []
      @body = body || issue&.body
    end

    def self.call(...)
      new(...).call
    end

    def self.extract(body:, comments: [])
      new(issue: nil, body: body, comments: comments).extract
    end

    def call
      raise ArgumentError, "issue is required" if issue.nil?

      local_deps, cross_deps = extract

      current_deps = issue.issue_dependencies.to_a
      current_local_by_id = current_deps.select(&:local?).index_by(&:depends_on_issue_id)
      current_external_by_key = current_deps.select(&:external?).index_by do |d|
        [ d.depends_on_owner.downcase, d.depends_on_repo.downcase, d.depends_on_number ]
      end

      return if local_deps.empty? && cross_deps.empty? &&
               current_local_by_id.empty? && current_external_by_key.empty?

      new_local_deps = sync_local_deps(local_deps, current_local_by_id)
      current_state = { local_by_id: current_local_by_id, external_by_key: current_external_by_key }
      new_cross_refs = sync_cross_project_deps(cross_deps, local_deps, current_state, new_local_deps)

      kept_local_ids = new_local_deps.keys.to_set | new_cross_refs[:resolved_ids]
      remove_stale_local_deps(current_local_by_id.keys.to_set, kept_local_ids)
      remove_stale_external_deps(current_external_by_key.keys.to_set, new_cross_refs[:external_keys])
    end

    def extract
      local_deps, cross_deps = resolve_dependencies

      [ local_deps, cross_deps ]
    end

    private

    # Processes body then comments in the order given. Within a single comment,
    # removals take precedence over additions. Across comments, a later
    # directive can override an earlier one (e.g., re-add after removal).
    # Callers must supply comments sorted oldest-first for correct semantics.
    #
    # Returns two hashes keyed by ref identifier with boolean values indicating
    # whether the resulting dependency requires deployment:
    #   local_deps:  { github_number => requires_deployment? }
    #   cross_deps:  { [owner, repo, number] => requires_deployment? }
    def resolve_dependencies
      local_deps = {}
      cross_deps = {}

      if body.present?
        extract_body_refs(body, local_deps, cross_deps)
      end

      comments.each do |comment_body|
        next if comment_body.blank?

        added_local = {}
        added_cross = {}
        extract_body_refs(comment_body, added_local, added_cross)

        removed_local = Set.new
        removed_cross = Set.new
        extract_removal_refs(comment_body, removed_local, removed_cross)

        # Within a single comment, removals win over additions.
        removed_local.each { |num| added_local.delete(num) }
        removed_cross.each { |key| added_cross.delete(key) }

        merge_refs(local_deps, added_local)
        merge_refs(cross_deps, added_cross)
        removed_local.each { |num| local_deps.delete(num) }
        removed_cross.each { |key| cross_deps.delete(key) }
      end

      [ local_deps, cross_deps ]
    end

    # Merges new ref additions into the running map. A deployment flag, once
    # set by any directive, sticks until the ref is removed — so upgrading a
    # plain "Depends on #N" to "Awaits deployment of #N" later in the text
    # promotes the dep, but a later "Depends on #N" cannot silently downgrade
    # a deployment dep. Explicit removal + re-add resets the flag.
    def merge_refs(dest, src)
      src.each do |key, requires_deployment|
        dest[key] = true if requires_deployment
        dest[key] = false unless dest.key?(key)
      end
    end

    # Extracts both local (#N) and cross-repo (owner/repo#N) removal refs.
    # INLINE_REMOVAL_PATTERN has a single capture group, so scan yields
    # one-element arrays. Parenthesized destructuring |(refs_str)| extracts
    # the captured String directly — without it, refs_str would be an Array.
    def extract_removal_refs(text, local_numbers, cross_refs)
      text.scan(INLINE_REMOVAL_PATTERN) do |(refs_str)|
        refs_str.scan(CROSS_REPO_REF_PATTERN) do |owner, repo, number|
          cross_refs << [ owner.downcase, repo.downcase, number.to_i ]
        end
        stripped = refs_str.gsub(CROSS_REPO_REF_PATTERN, "")
        stripped.scan(ISSUE_REF_PATTERN) { |(num)| local_numbers << num.to_i }
      end
    end

    # Extracts refs from body using both dependency sections and inline patterns.
    # Only dependency-scoped text is parsed — incidental #N mentions (e.g. in a
    # "Notes" section) are intentionally ignored. Child/sub-issue listing
    # sections are stripped before inline extraction so dependency phrases
    # describing inter-sub-issue relationships are not attributed to the
    # current issue.
    def extract_body_refs(body, local_deps, cross_deps)
      markdown_sections(body, heading_pattern: DEPENDENCY_HEADING_PATTERN).each do |section_body|
        extract_section_refs(section_body, local_deps, cross_deps)
      end

      inline_text = strip_markdown_sections(body, heading_pattern: CHILD_LISTING_HEADING_PATTERN)
      extract_inline_refs(inline_text, local_deps, cross_deps)
    end

    # Within a "## Dependencies" section, recognise both explicit
    # "awaits/depends on/blocked by deployment of #N" phrasing and the shorter
    # list-item style "- Deployment of #N". Remaining refs are treated as
    # plain dependencies.
    def extract_section_refs(section_body, local_deps, cross_deps)
      scratch = section_body.dup

      [ INLINE_DEPLOYMENT_PATTERN, SECTION_DEPLOYMENT_PATTERN ].each do |pattern|
        scratch.scan(pattern) do |(refs_str)|
          extract_all_refs(refs_str, local_deps, cross_deps, requires_deployment: true)
        end
        scratch = scratch.gsub(pattern, "")
      end

      scratch = scratch.gsub(NON_DEPENDENCY_PATTERN, "")

      extract_all_refs(scratch, local_deps, cross_deps, requires_deployment: false)
    end

    # Extracts refs from inline "Depends on" / "Blocked by" / deployment patterns.
    # Deployment-phrased matches are consumed first so the plain pattern does
    # not double-count them as non-deployment deps.
    def extract_inline_refs(text, local_deps, cross_deps)
      scratch = text.dup

      scratch = scratch.gsub(NON_DEPENDENCY_PATTERN, "")

      scratch.scan(INLINE_DEPLOYMENT_PATTERN) do |(refs_str)|
        extract_all_refs(refs_str, local_deps, cross_deps, requires_deployment: true)
      end
      scratch = scratch.gsub(INLINE_DEPLOYMENT_PATTERN, "")

      scratch.scan(INLINE_DEPENDS_PATTERN) do |(refs_str)|
        extract_all_refs(refs_str, local_deps, cross_deps, requires_deployment: false)
      end
    end

    # Extracts both cross-repo and local issue refs from a string of refs.
    # Cross-repo tuples are normalized to lowercase for consistent comparison
    # (e.g., removal of "Owner/Repo#1" matches addition of "owner/repo#1").
    # `requires_deployment: true` sets a sticky flag on the ref — once set,
    # it cannot be silently cleared by a later non-deployment mention of the
    # same ref (only explicit removal clears it).
    def extract_all_refs(text, local_deps, cross_deps, requires_deployment:)
      text.scan(CROSS_REPO_REF_PATTERN) do |owner, repo, number|
        key = [ owner.downcase, repo.downcase, number.to_i ]
        cross_deps[key] = true if requires_deployment
        cross_deps[key] = false unless cross_deps.key?(key)
      end

      stripped = text.gsub(CROSS_REPO_REF_PATTERN, "")
      stripped.scan(ISSUE_REF_PATTERN) do |(num)|
        n = num.to_i
        local_deps[n] = true if requires_deployment
        local_deps[n] = false unless local_deps.key?(n)
      end
    end

    # Returns a Hash mapping dep_issue_id => IssueDependency record for every
    # local dep persisted in this run (either reused from current_local_by_id
    # or freshly created). The record handle is needed by sync_cross_project_deps
    # so a later cross-repo ref for the same local issue can promote the dep's
    # requires_deployment flag without losing it.
    def sync_local_deps(local_deps, current_local_by_id)
      new_local_deps = {}
      return new_local_deps if local_deps.empty?

      referenced_numbers = local_deps.keys

      # Include pull requests so "Depends on #N" resolves when #N is a PR
      # in the same project. Blocking on an open PR is what the user
      # declared; blocking on a closed/merged PR is a satisfied dep and
      # ready_for_work will correctly not treat it as blocking — unless the
      # dep is deployment-flagged and the PR has not been marked deployed.
      project_issues = issue.project.issues
        .where(github_number: referenced_numbers)
        .index_by(&:github_number)

      adj = adjacency || IssueDependency.account_adjacency(issue.project.account)

      referenced_numbers.each do |number|
        dep_issue = project_issues[number]
        next unless dep_issue
        next if dep_issue.id == issue.id

        requires_deployment = local_deps[number]

        if (existing = current_local_by_id[dep_issue.id])
          update_deployment_flag(existing, requires_deployment)
          new_local_deps[dep_issue.id] = existing
          next
        end

        next if would_create_cycle?(dep_issue, adj)

        new_local_deps[dep_issue.id] = issue.issue_dependencies.create!(
          depends_on_issue: dep_issue,
          requires_deployment: requires_deployment
        )
      end

      new_local_deps
    end

    def sync_cross_project_deps(cross_deps, local_deps, current_state, new_local_deps)
      current_local_by_id = current_state[:local_by_id]
      current_external_by_key = current_state[:external_by_key]
      resolved_ids = Set.new
      external_keys = Set.new
      return { resolved_ids: resolved_ids, external_keys: external_keys } if cross_deps.empty?

      account = issue.project.account
      adj = adjacency || IssueDependency.account_adjacency(account)

      cross_refs = cross_deps.keys
      project_lookup = build_project_lookup(account, cross_refs)
      issues_by_project = build_issue_lookup(project_lookup, cross_refs)

      cross_refs.each do |owner, repo, number|
        requires_deployment = cross_deps[[ owner, repo, number ]]
        project_key = [ owner.downcase, repo.downcase ]
        project = project_lookup[project_key]
        # Preserve the deployment flag from a matching local ref so a plain
        # self-repo cross-ref (e.g. "Depends on owner/repo#N") cannot silently
        # downgrade a dep that a local "Awaits deployment of #N" already
        # promoted. Mirrors the stickiness contract enforced by merge_refs.
        if project&.id == issue.project_id && local_deps[number]
          requires_deployment = true
        end

        if project
          dep_issue = issues_by_project.dig(project.id, number)

          if dep_issue
            resolved_ids << dep_issue.id
            if (existing = current_local_by_id[dep_issue.id])
              update_deployment_flag(existing, requires_deployment)
              next
            end
            # A local ref (e.g. "#123") earlier in the body may have already
            # created this dep without the deployment flag. Promote it here
            # instead of silently dropping the cross-repo ref's deployment
            # wording.
            if (just_created = new_local_deps[dep_issue.id])
              update_deployment_flag(just_created, requires_deployment)
              next
            end
            next if would_create_cycle?(dep_issue, adj)

            issue.issue_dependencies.create!(
              depends_on_issue: dep_issue,
              requires_deployment: requires_deployment
            )
            next
          end
        end

        # Store as external reference with normalized (downcased) owner/repo
        key = [ owner.downcase, repo.downcase, number ]
        external_keys << key
        if (existing = current_external_by_key[key])
          update_deployment_flag(existing, requires_deployment)
          next
        end

        issue.issue_dependencies.create!(
          depends_on_owner: owner.downcase,
          depends_on_repo: repo.downcase,
          depends_on_number: number,
          requires_deployment: requires_deployment
        )
      end

      { resolved_ids: resolved_ids, external_keys: external_keys }
    end

    def update_deployment_flag(dependency, requires_deployment)
      return if dependency.requires_deployment == requires_deployment

      dependency.update!(requires_deployment: requires_deployment)
    end

    def markdown_sections(text, heading_pattern:)
      sections = []
      buffer = nil

      each_markdown_line(text) do |line, in_fenced_code_block|
        if in_fenced_code_block
          buffer << line if buffer
          next
        end

        heading = markdown_heading_text(line)
        if heading
          sections << buffer.join if buffer
          buffer = heading.match?(heading_pattern) ? [] : nil
          next
        end

        buffer << line if buffer
      end

      sections << buffer.join if buffer
      sections
    end

    def strip_markdown_sections(text, heading_pattern:)
      output = +""
      skipping = false

      each_markdown_line(text) do |line, in_fenced_code_block|
        if in_fenced_code_block
          output << line unless skipping
          next
        end

        heading = markdown_heading_text(line)
        if heading
          skipping = heading.match?(heading_pattern)
          output << line unless skipping
          next
        end

        output << line unless skipping
      end

      output
    end

    def each_markdown_line(text)
      return enum_for(__method__, text) unless block_given?

      in_fenced_code_block = false

      text.to_s.scan(/.*?(?:\r?\n|\z)/) do |line|
        yield line, in_fenced_code_block
        in_fenced_code_block = !in_fenced_code_block if line.match?(FENCED_CODE_BLOCK_PATTERN)
      end
    end

    def markdown_heading_text(line)
      match_data = MARKDOWN_HEADING_PATTERN.match(line)
      match_data[1] if match_data
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

      # Include pull requests so a fully-qualified self-reference like
      # "Depends on owner/repo#N" resolves to the local row when #N is a PR
      # rather than falling through to the external-dep branch (which
      # would block unconditionally). ready_for_work evaluates the target's
      # github_state, so closed/merged PRs correctly do not block.
      result = {}
      refs_by_project_id.each do |project_id, numbers|
        issues = Issue.where(project_id: project_id, github_number: numbers.to_a)
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
