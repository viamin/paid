# frozen_string_literal: true

module FeatureIntents
  # Publishes one coherent-but-not-ready task as a planning-held GitHub issue
  # (CONFIDENCE-DELIVERY-002). The published issue carries the workflow-owned
  # planning label and explicit parent/dependency text, is linked to its
  # feature and prerequisite facets, and enters the tree at `release_state:
  # "held"` so only `ReleaseIssue`/`RunAdmission` may release it. Speculative
  # alternatives stay in Paid on the feature record — they never require
  # GitHub issues.
  #
  # Idempotency and concurrency: each task identity (feature + title digest)
  # embeds a stable marker in the remote body, publication serializes on a
  # session advisory lock (no row lock or transaction spans a GitHub call),
  # a lost local record is recovered from the remote body, and remote writes
  # are read back before any local link is committed. A failed write raises
  # for the caller to retry.
  # @spec CONFIDENCE-DELIVERY-002
  class PublishHeldIssue
    PLANNING_LABEL = ReleaseIssue::PLANNING_LABEL
    TASK_KINDS = FeatureIntentIssuePublication::TASK_KINDS

    ADVISORY_LOCK_SQL = "SELECT pg_advisory_lock($1, $2)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock($1, $2)".freeze
    LOCK_NAMESPACE = 1_357_180_009

    Result = Data.define(:issue, :link, :reused, :speculative_alternatives) do
      def published? = issue.present?
      def reused? = reused
    end

    def self.call(...) = new(...).call

    def initialize(feature_intent:, title:, body: "", parent_issue: nil, dependencies: [],
      speculative_alternatives: [], facet_prerequisites: [], task_kind: "implementation", client: nil)
      @feature_intent = feature_intent
      @title = title.to_s
      @body = body.to_s
      @parent_issue = parent_issue
      @dependencies = Array(dependencies)
      @speculative_alternatives = Array(speculative_alternatives)
      @facet_prerequisites = Array(facet_prerequisites)
      @task_kind = task_kind.to_s
      @client = client || feature_intent.project.client
    end

    def call
      raise ArgumentError, "title is required" if @title.strip.empty?
      raise ArgumentError, "task_kind must be one of: #{TASK_KINDS.join(', ')}" unless TASK_KINDS.include?(task_kind)
      return Result.new(issue: nil, link: nil, reused: false, speculative_alternatives: []) unless feature_intent.confidence_driven?

      issue, reused = with_publication_lock { publish_issue }
      attach_parent(issue)
      # Dependency edges are recorded before the feature link so
      # AttachFromAgentRun can mirror them as in-tree prerequisite edges.
      attach_dependencies(issue)
      link = link_issue(issue)
      ensure_task_kind_consistent!(link)
      record_planning_hold_contract(link)
      record_facet_prerequisites(link)
      alternatives = record_speculative_alternatives
      log_publication(issue:, reused:)
      Result.new(issue:, link:, reused:, speculative_alternatives: alternatives)
    end

    private

    attr_reader :feature_intent, :title, :body, :parent_issue, :dependencies, :speculative_alternatives, :task_kind,
      :facet_prerequisites, :client

    def project = feature_intent.project

    def digest = @digest ||= Digest::SHA256.hexdigest(title)[0, 16]

    def marker = "<!-- paid:planning-held:#{feature_intent.id}:#{digest} -->"

    def publish_issue
      ensure_receipt_task_kind_consistent!(publication_receipt)
      existing_issue || reconcile_receipted_issue || create_remote_issue
    end

    # The marker is the stable identity of this task under this feature, so a
    # repeated publication (retry, re-dispatch) reuses the already-filed issue
    # instead of duplicating it. Read it back first: GitHub's planning hold and
    # required links may have changed since the local issue was synchronized.
    def existing_issue
      local = project.issues.where("body LIKE ?", "%#{marker}%").order(:id).first
      if local
        ensure_task_kind_consistent!(publication_link(local))
        verify_read_back_number(local.github_number)
        return [ local, true ]
      end

      recovered = recovered_remote_issue
      return [ recovered, true ] if recovered

      nil
    end

    # A worker can terminate after GitHub accepts the create but before the
    # local upsert; recover that issue from its remote body rather than file a
    # duplicate.
    def recovered_remote_issue
      remote = remote_issue_with_marker
      return unless remote

      verify_remote_reuse(remote)
      Issues::UpsertFromGithub.call(project:, github_issue: remote)
    end

    # A receipt prevents a retry from issuing another create while the first
    # create may still be invisible to GitHub search. Once GitHub has returned
    # an issue number, reconciliation reads that exact issue instead.
    def reconcile_receipted_issue
      receipt = publication_receipt
      return unless receipt

      ensure_receipt_task_kind_consistent!(receipt)

      remote = receipt.remote_issue_number ? client.issue(project.full_name, receipt.remote_issue_number) : remote_issue_with_marker
      raise GithubClient::Error, "planning-held issue creation is pending remote reconciliation" unless remote

      verify_remote_reuse(remote)
      record_remote_issue!(receipt, remote) unless receipt.remote_issue_number
      [ Issues::UpsertFromGithub.call(project:, github_issue: remote), true ]
    end

    def create_remote_issue
      receipt = reserve_publication!
      return reconcile_receipted_issue if receipt.remote_issue_number

      remote = client.create_issue(
        project.full_name,
        title: title.truncate(255),
        body: composed_body,
        labels: planning_hold_required? ? [ PLANNING_LABEL ] : []
      )
      verify_read_back(remote)
      record_remote_issue!(receipt, remote)
      issue = Issues::UpsertFromGithub.call(project:, github_issue: remote)
      [ issue, false ]
    end

    def publication_receipt
      FeatureIntentIssuePublication.find_by(feature_intent:, task_digest: digest)
    end

    def reserve_publication!
      FeatureIntentIssuePublication.create_or_find_by!(feature_intent:, task_digest: digest) do |receipt|
        receipt.task_kind = task_kind
      end
    end

    def record_remote_issue!(receipt, remote)
      receipt.update!(remote_issue_id: remote.id, remote_issue_number: remote.number)
    end

    def remote_issue_with_marker
      return unless client.respond_to?(:search_issues)

      client.search_issues("repo:#{project.full_name} in:body \"#{marker}\"", per_page: 100).items
        .find { |candidate| candidate.body.to_s.include?(marker) }
    end

    def verify_read_back(remote)
      verify_read_back_number(remote.number)
    end

    def verify_remote_reuse(remote)
      existing_issue = project.issues.find_by(github_number: remote.number)
      ensure_task_kind_consistent!(publication_link(existing_issue)) if existing_issue
      verify_read_back(remote)
    end

    def verify_read_back_number(number)
      verified = client.issue(project.full_name, number)
      raise GithubClient::Error, "planning-held issue body was not read back" unless verified.body.to_s.include?(marker)
      if planning_hold_required? && !label_names(verified).include?(PLANNING_LABEL)
        raise GithubClient::Error, "planning hold was not read back"
      end

      missing = expected_body_lines.reject { |line| verified.body.to_s.include?(line) }
      raise GithubClient::Error, "planning-held issue links were not read back" if missing.any?
    end

    def label_names(remote)
      Array(remote.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s }
    end

    def composed_body
      parts = [ body.presence, "---" ]
      parts << "Sub-issue of ##{parent_issue.github_number}" if parent_issue
      lines = dependency_lines
      if lines.any?
        parts << ProjectConventions::IssueDependencies.heading(project:, resolved: dependency_conventions)
        parts << lines.map { |line| "- #{line}" }.join("\n")
      end
      parts << marker
      parts.compact.join("\n\n")
    end

    def expected_body_lines
      lines = dependency_lines.map { |line| "- #{line}" }
      lines << "Sub-issue of ##{parent_issue.github_number}" if parent_issue
      lines
    end

    def dependency_lines
      @dependency_lines ||= dependencies.filter_map do |dependency|
        next unless dependency.is_a?(Issue)

        ProjectConventions::IssueDependencies.depends_on_line(
          project:, github_number: dependency.github_number, resolved: dependency_conventions
        )
      end
    end

    def dependency_conventions
      @dependency_conventions ||= ProjectConventions::IssueDependencies.convention_value(project)
    end

    def link_issue(issue)
      AttachFromAgentRun.attach_issue(feature_intent:, issue:)
      feature_intent.feature_intent_issues.find_by!(issue: issue)
    end

    def publication_link(issue)
      feature_intent.feature_intent_issues.find_by(issue: issue)
    end

    # The publication marker identifies one durable task. A retry must not
    # change its admission semantics by replacing its persisted task kind.
    # @spec CONFIDENCE-DELIVERY-017
    def ensure_task_kind_consistent!(link)
      stored_task_kind = link&.readiness_mapping&.dig("planning_hold", "task_kind").presence
      return if stored_task_kind.blank? || stored_task_kind == task_kind

      raise ArgumentError, "task_kind conflicts with the existing publication"
    end

    def ensure_receipt_task_kind_consistent!(receipt)
      return if receipt.nil? || receipt.task_kind == task_kind

      raise ArgumentError, "task_kind conflicts with the existing publication"
    end

    # The existing readiness mapping is the durable per-task contract. Keeping
    # provenance beside the scoped evidence lets reconciliation distinguish a
    # Paid-owned hold from a legacy/operator `planning` label without a second
    # state machine or a migration-only record.
    # @spec CONFIDENCE-DELIVERY-017
    def record_planning_hold_contract(link)
      contract = {
        "owner" => FeatureIntentIssue::PAID_HOLD_OWNER,
        "task_kind" => task_kind,
        "operator_override" => link.readiness_mapping.dig("planning_hold", "operator_override") || false,
        "reason" => "Awaiting the scoped planning release condition.",
        "release_condition" => "Current scoped readiness and dependencies permit implementation.",
        "scope_revision" => "published-#{digest}",
        "provenance" => { "source" => "publish_held_issue", "task_digest" => digest }
      }
      link.update!(readiness_mapping: link.readiness_mapping.deep_merge("planning_hold" => contract))
    end

    def planning_hold_required? = task_kind != FeatureIntentIssue::PLANNING_TASK_KIND

    # The parent link is a contextual relationship, deliberately not a
    # blocking dependency; the planning hold and facet readiness own blocking.
    def attach_parent(issue)
      return if parent_issue.nil? || issue.parent_issue_id.present?

      issue.update!(parent_issue: parent_issue)
    end

    def attach_dependencies(issue)
      dependencies.each do |dependency|
        next unless dependency.is_a?(Issue)

        persist_dependency!(issue, dependency)
        link_dependency_issue(dependency)
      end
    end

    # Attach prerequisite issues before their dependent so AttachFromAgentRun
    # can record the IssueDependency as an in-tree prerequisite edge.
    def link_dependency_issue(dependency)
      AttachFromAgentRun.attach_issue(feature_intent:, issue: dependency)
      feature_intent.feature_intent_issues.find_by!(issue: dependency)
    end

    # IssueDependency uniqueness is a model validation, so a repeated
    # publication edge surfaces as RecordInvalid rather than RecordNotUnique;
    # an already-recorded edge is the desired idempotent outcome.
    def persist_dependency!(issue, dependency)
      IssueDependency.create!(issue: issue, depends_on_issue: dependency)
    rescue ActiveRecord::RecordInvalid => error
      raise unless duplicate_dependency?(error)

      IssueDependency.find_by!(issue: issue, depends_on_issue: dependency)
    end

    def duplicate_dependency?(error)
      error.record.errors.of_kind?(:depends_on_issue_id, :taken)
    end

    # Facet prerequisites make the published issue's readiness assessable.
    # Coverage stays "unknown" here — confirming material coverage is the
    # assessor's semantic judgment, never implied by publication, so an
    # unassessed issue can never pass readiness by absence of evidence.
    def record_facet_prerequisites(link)
      entries = facet_prerequisites.filter_map { |entry| facet_entry(entry) }
      return if entries.empty?

      mapping = FeatureIntentIssuePrerequisiteMapping.create_or_find_by!(
        feature_intent_issue: link,
        account: project.account
      ) { |record| record.coverage_assessment = "unknown" }
      mapping.update!(scope_revision: "published-#{digest}") if mapping.scope_revision.blank?
      entries.each do |entry|
        mapping.prerequisites.find_or_create_by!(
          feature_intent_facet: entry.fetch(:facet),
          feature_intent_facet_direction: entry.fetch(:direction)
        ) do |record|
          record.account = project.account
          record.materiality_rationale = entry.fetch(:rationale)
        end
      end
    end

    def facet_entry(entry)
      facet = entry[:facet] || entry["facet"]
      return unless facet.is_a?(FeatureIntentFacet)

      {
        facet: facet,
        direction: entry[:direction] || entry["direction"],
        rationale: (entry[:rationale] || entry["rationale"]).to_s.presence || "Material prerequisite for the published scope."
      }
    end

    # Speculative alternatives remain Paid-visible on the feature without
    # GitHub issues; recording is deduplicated by title so repeated
    # publication attempts do not duplicate the alternatives either.
    def record_speculative_alternatives
      entries = speculative_alternatives.filter_map { |alternative| alternative_entry(alternative) }
      return feature_intent.speculative_alternatives if entries.empty?

      feature_intent.with_lock do
        existing = feature_intent.reload.speculative_alternatives
        known_titles = existing.map { |alternative| alternative["title"].to_s.downcase }.to_set
        additions = entries.reject { |alternative| known_titles.include?(alternative["title"].downcase) }
        return existing if additions.empty?

        merged = existing + additions
        feature_intent.update!(speculative_alternatives: merged)
        merged
      end
    end

    def alternative_entry(alternative)
      attributes = alternative.is_a?(Hash) ? alternative.transform_keys(&:to_s) : {}
      title = attributes["title"].to_s.strip
      return if title.empty?

      {
        "title" => title.truncate(255),
        "summary" => attributes["summary"].to_s.truncate(2_000),
        "recorded_at" => Time.current.iso8601
      }
    end

    def with_publication_lock
      raw_connection = ActiveRecord::Base.connection.raw_connection
      lock_key = Zlib.crc32("#{feature_intent.id}:#{digest}") % 2_147_483_647
      raw_connection.exec_params(ADVISORY_LOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
      locked = true
      yield
    ensure
      raw_connection&.exec_params(ADVISORY_UNLOCK_SQL, [ LOCK_NAMESPACE, lock_key ]) if locked
    end

    def log_publication(issue:, reused:)
      Rails.logger.info(
        message: "feature_intent.planning_held_issue_published",
        feature_intent_id: feature_intent.id,
        issue_id: issue.id,
        github_number: issue.github_number,
        reused: reused
      )
    end
  end
end
