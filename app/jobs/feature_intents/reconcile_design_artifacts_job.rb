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

      @issue_coverage_snapshot = IssueCoverageSnapshot.new(project:)
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
      @reconciliation_query_count = 0
      logger.info(message: "feature_intents.reconciliation_started", project_id: arguments.first,
        job_id:, rss_kb: memory_before[:rss_kb])
      ActiveSupport::Notifications.subscribed(method(:count_reconciliation_query), "sql.active_record") { yield }
      completed = true
    ensure
      memory_after = process_memory
      logger.info(message: "feature_intents.reconciliation_finished", project_id: arguments.first, job_id:,
        status: completed ? "completed" : "failed", artifacts_reconciled: @reconciled_artifact_count,
        issue_facts: @issue_coverage_snapshot&.fact_count || 0, query_count: @reconciliation_query_count,
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

    def count_reconciliation_query(event)
      payload = event.payload
      @reconciliation_query_count += 1 unless payload[:cached] || payload[:name] == "SCHEMA"
    end

    def design_pull_request(pull_request_number)
      FeatureIntentDesignPr.joins(:feature_intent).find_by(
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
        stored_identities: issue_coverage_snapshot.identities_for_feature_intent(design_pr.feature_intent_id),
        associated_issues: issue_coverage_snapshot.feature_associations(design_pr.feature_intent_id),
        coverage_complete: issue.present? && design_pr.draft.in?([ true, false ])
      }
    end

    def project_issue(number)
      @project_issue ||= {}
      @project_issue[number] ||= project.issues.find_by(github_number: number)
    end

    def reconcile_rdr_artifacts
      discovery = DiscoverRdrArtifacts.call(project:)
      discovery.artifacts.each do |artifact|
        reconcile(rdr_artifact(artifact), revision: artifact.revision,
          coverage_complete: discovery.complete? && !artifact.body.nil?)
      end
      resolve_removed_rdr_findings(discovery.artifacts) if discovery.complete?
    end

    def resolve_removed_rdr_findings(artifacts)
      convention = DiscoverRdrArtifacts.convention_for(project)
      PersistDesignArtifactFindings.resolve_removed_rdr_findings(
        project:, paths: artifacts.map(&:path), directory: convention.directory, file_pattern: convention.file_pattern
      )
    end

    def reconcile_project_artifacts
      @issue_coverage_snapshot = IssueCoverageSnapshot.new(project:)
      reconcile_rdr_artifacts
      open_design_pull_requests.find_each do |design_pr|
        reconcile(artifact_for(design_pr), revision: design_pr.head_sha)
      end
    end

    def open_design_pull_requests
      FeatureIntentDesignPr.joins(:feature_intent).where(
        feature_intents: { project_id: project.id }, merged_at: nil
      )
    end

    def reconcile(artifact, revision:, coverage_complete: true)
      issues, complete, associated_issues = issue_coverage_snapshot.coverage_for(
        references: artifact.fetch(:related_issues), associated_issues: Array(artifact[:associated_issues]),
        artifact_path: artifact.fetch(:path)
      )
      PersistDesignArtifactFindings.call(
        project:, revision:, artifacts: [ artifact.merge(associated_issues:) ], issues:,
        coverage_complete: coverage_complete && artifact.fetch(:coverage_complete, true) && complete
      )
      @reconciled_artifact_count += 1
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

    def issue_coverage_snapshot
      @issue_coverage_snapshot ||= IssueCoverageSnapshot.new(project:)
    end

    def repository_for(reference)
      reference.split("#", 2).first
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

    class << self
      def relationship_text(body)
        new.send(:relationship_text, body)
      end
    end
  end
end
