# frozen_string_literal: true

module FeatureIntents
  # Reconciles one known design pull request using the synchronized local
  # issue mirror. GitHub synchronization is the authority for both inputs;
  # this job never makes write calls to GitHub.
  # @spec DESIGN-RECONCILIATION-001
  class ReconcileDesignArtifactsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    RDR_STATUS_PATTERN = /^\s*(?:[-*]\s+)?(?:\*\*)?status(?:\*\*)?\s*:\s*(?:\*\*)?(.+?)(?:\*\*)?\s*$/i
    RELATIONSHIP_LINE_PATTERN = /^\s*(?:[-*]\s+)?(?:\*\*)?(?:implements|closes|fixes|resolves|tracks|depends on|blocked by|related issues?)(?:\s*:)?(?:\*\*)?\s*:?\s+(.+)$/i
    RELATIONSHIP_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+(?:\*\*)?(?:implements|closes|fixes|resolves|tracks|depends on|blocked by|related issues?)(?:\*\*)?\s*#*\s*$/i
    MARKDOWN_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+/
    OWNERSHIP_HEADING_PATTERN = /^\s{0,3}\#{1,6}\s+(?:\*\*)?(?:issue |work |implementation )?ownership(?:\*\*)?\s*$/i
    GITHUB_ISSUE_URL_PATTERN = %r{https?://github\.com/([\w.-]+)/([\w.-]+)/issues/(\d+)}i
    QUALIFIED_ISSUE_PATTERN = %r{(?<![\w./-])([\w.-]+/[\w.-]+)#(\d+)}
    BARE_ISSUE_PATTERN = %r{(?<![\w./-])#(\d+)}
    FILE_EXTENSION_PATTERN = /\.[a-z0-9]{1,4}\z/i
    COALESCING_WINDOW = 30.seconds

    queue_as :maintenance

    good_job_control_concurrency_with(
      enqueue_limit: 1,
      perform_limit: 1,
      key: -> { "design_artifact_reconciliation_#{arguments.first}_#{arguments.second}" }
    )

    discard_on ActiveRecord::RecordNotFound
    around_perform :profile_memory

    # @spec DESIGN-RECONCILIATION-002
    def self.enqueue_for(project_id)
      ActiveRecord.after_all_transactions_commit do
        set(wait: COALESCING_WINDOW).perform_later(project_id)
      end
    end

    def perform(project_id, pull_request_number = nil)
      @project = Project.find(project_id)
      return reconcile_project_artifacts unless pull_request_number

      design_pr = design_pull_request(pull_request_number)
      reconcile(artifact_for(design_pr), revision: design_pr.head_sha) if design_pr
    end

    private

    attr_reader :project

    # Measurements describe this process, including concurrent work, rather
    # than an isolated Ruby heap for this job. VmHWM is the process lifetime peak.
    # @spec DESIGN-RECONCILIATION-002
    def profile_memory
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      allocated_before = GC.stat(:total_allocated_objects)
      memory_before = process_memory
      completed = false
      @reconciled_artifact_count = 0
      logger.info(message: "feature_intents.reconciliation_started", project_id: arguments.first,
        job_id:, rss_kb: memory_before[:rss_kb])
      yield
      completed = true
    ensure
      memory_after = process_memory
      logger.info(message: "feature_intents.reconciliation_finished", project_id: arguments.first, job_id:,
        status: completed ? "completed" : "failed", artifacts_reconciled: @reconciled_artifact_count,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1),
        allocated_objects: GC.stat(:total_allocated_objects) - allocated_before,
        rss_before_kb: memory_before[:rss_kb], rss_after_kb: memory_after[:rss_kb],
        process_peak_rss_kb: memory_after[:peak_rss_kb])
    end

    def process_memory
      status = File.read("/proc/self/status")
      { rss_kb: status[/^VmRSS:\s+(\d+)/, 1]&.to_i, peak_rss_kb: status[/^VmHWM:\s+(\d+)/, 1]&.to_i }
    rescue SystemCallError, IOError
      {}
    end

    def design_pull_request(pull_request_number)
      FeatureIntentDesignPr.joins(:feature_intent).includes(feature_intent: { issues: :project }).find_by(
        feature_intents: { project_id: project.id }, pull_request_number:
      )
    end

    def artifact_for(design_pr)
      issue = project_issue(design_pr.pull_request_number)
      {
        path: "pull/#{design_pr.pull_request_number}",
        revision: design_pr.head_sha,
        body: issue&.body,
        status: design_pr.draft? ? "draft" : nil,
        related_issues: explicit_references(issue&.body),
        stored_identities: design_pr.feature_intent.issues.map { |linked| identity_for(linked) },
        associated_issues: design_pr.feature_intent.issues.filter_map do |linked|
          association_for(linked, "Paid feature intent linkage")
        end,
        coverage_complete: issue.present? && design_pr.draft.in?([ true, false ])
      }
    end

    def project_issue(number)
      @project_issue ||= {}
      @project_issue[number] ||= project.issues.find_by(github_number: number)
    end

    def resolve_removed_rdr_findings(artifacts)
      convention = DiscoverRdrArtifacts.convention_for(project)
      PersistDesignArtifactFindings.resolve_removed_rdr_findings(
        project:, paths: artifacts.map(&:path), directory: convention.directory, file_pattern: convention.file_pattern
      )
    end

    def reconcile_project_artifacts
      discovery = DiscoverRdrArtifacts.call(project:)
      artifacts = discovery.artifacts.map { |artifact| [ rdr_artifact(artifact), artifact.revision, discovery.complete? && !artifact.body.nil? ] }
      open_design_pull_requests.find_each do |design_pr|
        artifacts << [ artifact_for(design_pr), design_pr.head_sha, true ]
      end
      reconcile_artifacts(artifacts)
      resolve_removed_rdr_findings(discovery.artifacts) if discovery.complete?
    end

    def open_design_pull_requests
      FeatureIntentDesignPr.joins(:feature_intent).includes(feature_intent: { issues: :project }).where(
        feature_intents: { project_id: project.id }, merged_at: nil
      )
    end

    def reconcile_artifacts(artifacts)
      return if artifacts.empty?

      coverage = IssueCoverageSnapshot.new(project:, artifacts: artifacts.map(&:first), relationship_text: method(:relationship_text))
      artifacts.each do |artifact, revision, coverage_complete|
        reconcile(artifact, revision:, coverage_complete:, coverage:)
      end
    end

    # @spec DESIGN-RECONCILIATION-003
    def reconcile(artifact, revision:, coverage_complete: true, coverage: nil)
      issues, complete, associated_issues = (coverage || IssueCoverageSnapshot.new(
        project:, artifacts: [ artifact ], relationship_text: method(:relationship_text)
      )).for(artifact)
      PersistDesignArtifactFindings.call(
        project:, revision:, artifacts: [ artifact.merge(associated_issues:) ], issues:,
        coverage_complete: coverage_complete && artifact.fetch(:coverage_complete, true) && complete
      )
      @reconciled_artifact_count += 1
    end

    # Holds only the fields reconciliation consumes, for the duration of one
    # job.  In particular, it does not retain an Active Record graph for every
    # synchronized issue or repeat the same query for every design artifact.
    class IssueCoverageSnapshot
      PROJECT_FIELDS = %i[id account_id owner repo allowed_github_usernames pr_target upstream_full_name github_installation_id].freeze
      ISSUE_FIELDS = %i[id project_id github_number github_state title body github_updated_at github_creator_login is_pull_request].freeze

      def initialize(project:, artifacts:, relationship_text:)
        @project = project
        @artifacts = artifacts
        @relationship_text = relationship_text
        @manifest_issue_links = load_manifest_issue_links
        @projects_by_repository = authorized_projects
        @projects_by_id = projects_by_repository.values.index_by(&:id)
        @facts_by_issue_id, @manifest_facts_by_issue_id = load_facts
        @facts = @facts_by_issue_id.values.reject { |fact| fact[:is_pull_request] }
        @manifest_associations_by_path = load_manifest_associations
        @exact_backlinks_by_path = load_exact_backlinks
      end

      def for(artifact)
        associations = Array(artifact[:associated_issues]) + exact_backlinks(artifact) + manifest_associations(artifact)
        referenced_repositories = artifact.fetch(:related_issues).map { |reference| repository_for(reference) }
        repositories = repositories_for(referenced_repositories, associations)
        artifact_facts = facts.select { |fact| repositories.include?(fact[:repository]) }
        [ artifact_facts, referenced_repositories.all? { |repository| projects_by_repository.key?(repository) }, associations ]
      end

      private

      attr_reader :project, :artifacts, :relationship_text, :projects_by_repository, :projects_by_id, :facts_by_issue_id,
        :facts, :manifest_facts_by_issue_id, :manifest_associations_by_path, :manifest_issue_links,
        :exact_backlinks_by_path

      def authorized_projects
        repositories = (referenced_repositories + associated_repositories + manifest_repositories).uniq - [ project.full_name ]
        external = Project.where(account_id: project.account_id, owner: repositories.map { |name| name.split("/").first },
          repo: repositories.map { |name| name.split("/").last }).select(*PROJECT_FIELDS).to_a
        external.append(project).index_by(&:full_name)
      end

      def referenced_repositories
        artifacts.flat_map { |artifact| artifact.fetch(:related_issues) }.map { |reference| repository_for(reference) }
      end

      def associated_repositories
        artifacts.flat_map { |artifact| Array(artifact[:associated_issues]) }.filter_map { |association| association[:repository] }
      end

      # Issues reachable only through the issue-tree manifest (never named in
      # an artifact body or stored association) still need their project
      # authorized here, or their facts are silently unavailable when
      # `load_manifest_associations` looks them up below.
      def manifest_repositories
        manifest_issue_links.map { |(_, _, owner, repo)| "#{owner}/#{repo}" }.uniq
      end

      def load_facts
        manifest_issue_ids = manifest_issue_links.map { |(_, issue_id, _, _)| issue_id }.to_set
        Issue.where(project_id: projects_by_repository.values.map(&:id)).where.not(github_number: nil).select(*ISSUE_FIELDS).find_each.each_with_object([ {}, {} ]) do |issue, (facts, manifest_facts)|
          project_for_issue = projects_by_id[issue.project_id]
          next unless project_for_issue

          fact = {
            id: issue.id, project_id: issue.project_id, repository: project_for_issue.full_name,
            number: issue.github_number, state: issue.github_state, title: issue.title, body: issue.body,
            revision: issue.github_updated_at&.iso8601, is_pull_request: issue.is_pull_request
          }
          facts[issue.id] = fact if trusted?(issue, project_for_issue)
          manifest_facts[issue.id] = fact if manifest_issue_ids.include?(issue.id)
        end
      end

      def trusted?(issue, issue_project)
        if issue_project.upstream_pr_target?
          issue_project.trusted_upstream_issue_author?(issue.github_creator_login)
        else
          issue_project.trusted_github_author?(issue.github_creator_login)
        end
      end

      def load_manifest_issue_links
        FeatureIntentIssue.joins(:feature_intent, issue: :project).where(feature_intents: { project_id: project.id })
          .pluck("feature_intents.design_document_paths", :issue_id, "projects.owner", "projects.repo")
      end

      def load_manifest_associations
        manifest_issue_links.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(paths, issue_id, _, _), associations|
          fact = manifest_facts_by_issue_id[issue_id]
          next unless fact

          Array(paths).each { |path| associations[path] << association_for(fact, "canonical issue-tree manifest") }
        end
      end

      def load_exact_backlinks
        patterns = artifacts.map { |artifact| [ artifact.fetch(:path), artifact_path_pattern(artifact.fetch(:path)) ] }.to_h
        local_facts.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |fact, backlinks|
          text = relationship_text.call(fact[:body])
          patterns.each do |path, pattern|
            next unless text.match?(pattern)

            backlinks[path] << association_for(fact, "exact artifact backlink")
          end
        end
      end

      def local_facts = facts.select { |fact| fact[:project_id] == project.id }

      def exact_backlinks(artifact) = exact_backlinks_by_path.fetch(artifact[:path], [])

      def manifest_associations(artifact) = manifest_associations_by_path.fetch(artifact[:path], [])

      def association_for(fact, provenance)
        { repository: fact[:repository], number: fact[:number], revision: fact[:revision], provenance:,
          project: projects_by_repository.fetch(fact[:repository]) }.compact
      end

      def repositories_for(referenced_repositories, associations)
        ([ project.full_name ] + referenced_repositories + associations.filter_map { |item| item[:repository] }).to_set
      end

      def repository_for(reference) = reference.split("#", 2).first

      def artifact_path_pattern(path) = /(?<![\w.\/-])#{Regexp.escape(path)}(?![\w.\/-])/
    end

    def association_for(issue, provenance)
      return unless issue.github_number

      {
        repository: issue.project.full_name,
        number: issue.github_number,
        revision: issue.github_updated_at&.iso8601,
        provenance:, project: issue.project
      }
    end

    def rdr_artifact(artifact)
      {
        path: artifact.path,
        revision: artifact.revision,
        body: artifact.body,
        status: rdr_status(artifact.body),
        related_issues: explicit_references(artifact.body),
        stored_identities: []
      }
    end

    def rdr_status(body)
      body.to_s[RDR_STATUS_PATTERN, 1]&.strip
    end

    def explicit_references(body)
      references_from(relationship_text(body)) + ownership_table_references(body)
    end

    def references_from(text, local_bare: true)
      urls = text.scan(GITHUB_ISSUE_URL_PATTERN).map { |owner, repo, number| "#{owner}/#{repo}##{number}" }
      without_links_or_urls = text.gsub(/\[[^\]]*\]\([^)]*\)/, "").gsub(%r{https?://\S+}, "")
      qualified = without_links_or_urls.scan(QUALIFIED_ISSUE_PATTERN).map { |repository, number| "#{repository}##{number}" }
      bare = local_bare ? without_links_or_urls.scan(BARE_ISSUE_PATTERN).flatten.map { |number| "#{project.full_name}##{number}" } : []
      (urls + qualified + bare).uniq
    end

    def ownership_table_references(body)
      ownership_table_text(body).flat_map do |line|
        repository = ownership_repository(line)
        references = references_from(line, local_bare: repository.nil?)
        references + bare_ownership_references(line, repository)
      end.uniq
    end

    def ownership_repository(line)
      repository = markdown_table_cells(line).first.to_s.strip[/\A([\w.-]+\/[\w.-]+)\z/, 1]
      repository unless repository&.match?(FILE_EXTENSION_PATTERN)
    end

    def bare_ownership_references(line, repository)
      return [] unless repository

      line.gsub(/\[[^\]]*\]\([^)]*\)/, "").gsub(%r{https?://\S+}, "")
        .scan(BARE_ISSUE_PATTERN).flatten.map { |number| "#{repository}##{number}" }
    end

    def ownership_table_text(body)
      rows = []
      expecting_separator = false
      in_table = false

      body.to_s.each_line do |line|
        if expecting_separator
          in_table = markdown_table_separator?(line)
          expecting_separator = false
        elsif in_table && markdown_table_row?(line)
          rows << line
        elsif in_table
          in_table = false
          expecting_separator = ownership_table_header?(line)
        else
          expecting_separator = ownership_table_header?(line)
        end
      end

      rows
    end

    def ownership_table_header?(line)
      markdown_table_row?(line) && line.match?(/\bowner(?:s|ship)?\b/i) && line.match?(/\b(?:issue|work)\b/i)
    end

    def markdown_table_row?(line)
      line.to_s.match?(/^\s*\|?[^|\n]+\|[^|\n]+(?:\|[^|\n]+)*\|?\s*$/)
    end

    def markdown_table_cells(line)
      line.to_s.strip.delete_prefix("|").delete_suffix("|").split("|").map(&:strip)
    end

    def markdown_table_separator?(line)
      line.to_s.match?(/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/)
    end

    def relationship_text(body)
      in_relationship_section = false
      in_ownership_table = false
      lines = body.to_s.each_line.to_a
      lines.each_with_index.filter_map do |line, index|
        if line.match?(OWNERSHIP_HEADING_PATTERN)
          in_relationship_section = false
          next
        end

        if ownership_table_header?(line) && markdown_table_separator?(lines[index + 1])
          in_relationship_section = false
          in_ownership_table = true
          next
        end

        if in_ownership_table
          if markdown_table_row?(line)
            next
          end

          in_ownership_table = false
        end

        if line.match?(RELATIONSHIP_HEADING_PATTERN)
          in_relationship_section = true
          next
        end

        in_relationship_section = false if line.match?(MARKDOWN_HEADING_PATTERN)

        in_relationship_section ? line : line[RELATIONSHIP_LINE_PATTERN, 1]
      end.join("\n")
    end

    def identity_for(issue)
      "#{issue.project.full_name}##{issue.github_number}"
    end
  end
end
