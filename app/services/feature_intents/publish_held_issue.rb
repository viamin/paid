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

    ADVISORY_LOCK_SQL = "SELECT pg_advisory_lock($1, $2)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock($1, $2)".freeze
    LOCK_NAMESPACE = 1_357_180_009

    Result = Data.define(:issue, :link, :reused, :speculative_alternatives) do
      def published? = issue.present?
      def reused? = reused
    end

    def self.call(...) = new(...).call

    def initialize(feature_intent:, title:, body: "", parent_issue: nil, dependencies: [],
      speculative_alternatives: [], facet_prerequisites: [], client: nil)
      @feature_intent = feature_intent
      @title = title.to_s
      @body = body.to_s
      @parent_issue = parent_issue
      @dependencies = Array(dependencies)
      @speculative_alternatives = Array(speculative_alternatives)
      @facet_prerequisites = Array(facet_prerequisites)
      @client = client || feature_intent.project.client
    end

    def call
      raise ArgumentError, "title is required" if @title.strip.empty?
      return Result.new(issue: nil, link: nil, reused: false, speculative_alternatives: []) unless feature_intent.confidence_driven?

      issue, reused = with_publication_lock { publish_issue }
      attach_parent(issue)
      # Dependency edges are recorded before the feature link so
      # AttachFromAgentRun can mirror them as in-tree prerequisite edges.
      attach_dependencies(issue)
      link = link_issue(issue)
      record_facet_prerequisites(link)
      alternatives = record_speculative_alternatives
      log_publication(issue:, reused:)
      Result.new(issue:, link:, reused:, speculative_alternatives: alternatives)
    end

    private

    attr_reader :feature_intent, :title, :body, :parent_issue, :dependencies, :speculative_alternatives,
      :facet_prerequisites, :client

    def project = feature_intent.project

    def digest = @digest ||= Digest::SHA256.hexdigest(title)[0, 16]

    def marker = "<!-- paid:planning-held:#{feature_intent.id}:#{digest} -->"

    def publish_issue
      existing_issue || create_remote_issue
    end

    # The marker is the stable identity of this task under this feature, so a
    # repeated publication (retry, re-dispatch) reuses the already-filed issue
    # instead of duplicating it.
    def existing_issue
      local = project.issues.where("body LIKE ?", "%#{marker}%").order(:id).first
      return [ local, true ] if local

      recovered = recovered_remote_issue
      return [ recovered, true ] if recovered

      nil
    end

    # A worker can terminate after GitHub accepts the create but before the
    # local upsert; recover that issue from its remote body rather than file a
    # duplicate.
    def recovered_remote_issue
      return unless client.respond_to?(:search_issues)

      client.search_issues("repo:#{project.full_name} in:body \"#{marker}\"", per_page: 100).items
        .find { |candidate| candidate.body.to_s.include?(marker) }
        &.then { |remote| Issues::UpsertFromGithub.call(project:, github_issue: remote) }
    end

    def create_remote_issue
      remote = client.create_issue(
        project.full_name,
        title: title.truncate(255),
        body: composed_body,
        labels: [ PLANNING_LABEL ]
      )
      verify_read_back(remote)
      issue = Issues::UpsertFromGithub.call(project:, github_issue: remote)
      [ issue, false ]
    end

    def verify_read_back(remote)
      verified = client.issue(project.full_name, remote.number)
      raise GithubClient::Error, "planning-held issue body was not read back" unless verified.body.to_s.include?(marker)
      raise GithubClient::Error, "planning hold was not read back" unless label_names(verified).include?(PLANNING_LABEL)

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
      end
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
