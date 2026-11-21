# frozen_string_literal: true

module WorkItems
  # Imports the legacy GitHub issue aggregate during the RDR-079 maintenance
  # window. The legacy row remains the immutable Paid-history record while the
  # unified work item becomes the provider-ticket identity for cutover.
  #
  # @spec UNIFIED-WORK-ITEMS-007 UNIFIED-WORK-ITEMS-009
  class MigrateGithubIssues
    IdentityConflictError = Class.new(StandardError)
    Result = Data.define(:migrated_count, :reconciled_count)

    def self.call(...)
      new(...).call
    end

    def initialize(account:, since: nil, comments: nil)
      @account = account
      @since = since
      @comments = comments || method(:fetch_comments)
    end

    def call
      TenantContext.with_system_access do
        migrated_count = 0
        reconciled_count = 0

        issues.find_each do |issue|
          migrated_count += 1 if migrate(issue)
          reconciled_count += 1 if since
        end

        Result.new(migrated_count:, reconciled_count:)
      end
    end

    private

    attr_reader :account, :since, :comments

    def issues
      scope = Issue.joins(:project)
        .where(projects: { account_id: account.id })
        .where(source: Issue::GITHUB_SOURCE, is_pull_request: false)
        .order(:id)
      return scope unless since

      scope.where("issues.github_created_at >= :since OR issues.github_updated_at >= :since", since:)
    end

    def migrate(issue)
      WorkItem.transaction do
        work_item = find_work_item(issue)
        created = work_item.new_record?
        work_item.assign_attributes(work_item_attributes(issue))
        work_item.save!
        preserve_assignment(work_item, issue)
        preserve_agent_run_history(work_item, issue)
        created
      end
    end

    def find_work_item(issue)
      existing = WorkItem.find_by(legacy_issue_id: issue.id) || WorkItem.find_by(
        account:, provider: "github", resource_type: "issue", external_id: issue.github_issue_id.to_s
      )
      return WorkItem.new(account:) unless existing
      return existing if existing.legacy_issue_id.blank? || existing.legacy_issue_id == issue.id

      raise IdentityConflictError, "GitHub issue #{issue.github_issue_id} maps to more than one legacy issue"
    end

    def work_item_attributes(issue)
      {
        legacy_issue: issue,
        provider: "github",
        resource_type: "issue",
        external_id: issue.github_issue_id.to_s,
        title: issue.title,
        body: issue.body,
        native_state: issue.github_state,
        paid_lifecycle_state: issue.paid_state,
        url: issue.github_url,
        provider_created_at: issue.github_created_at,
        provider_updated_at: issue.github_updated_at,
        last_synced_at: Time.current,
        raw_payload: migration_payload(issue)
      }
    end

    def migration_payload(issue)
      {
        "github" => issue_attributes(issue, %w[github_issue_id github_number github_creator_login github_html_url github_state labels]),
        "paid" => issue_attributes(issue, paid_attribute_names),
        "comments" => Array(comments.call(issue)).map { |comment| serializable(comment) },
        "relationships" => relationships(issue),
        "trusted_github_users" => issue.project.allowed_github_usernames,
        "migration" => {
          "legacy_issue_id" => issue.id,
          "migrated_at" => Time.current.iso8601
        }
      }
    end

    def issue_attributes(issue, names)
      issue.attributes.slice(*names)
    end

    def paid_attribute_names
      @paid_attribute_names ||= Issue.column_names - %w[
        id project_id title body source is_pull_request github_issue_id github_number
        github_creator_login github_html_url github_state github_created_at github_updated_at
        labels created_at updated_at
      ]
    end

    def relationships(issue)
      {
        "parent_issue_id" => issue.parent_issue_id,
        "sub_issue_ids" => issue.sub_issues.pluck(:id),
        "dependency_ids" => issue.issue_dependencies.where.not(depends_on_issue_id: nil).pluck(:depends_on_issue_id),
        "external_dependencies" => issue.issue_dependencies.where(depends_on_issue_id: nil).map { |dependency| serializable(dependency) },
        "dependent_issue_ids" => issue.reverse_issue_dependencies.pluck(:issue_id)
      }
    end

    def preserve_assignment(work_item, issue)
      WorkItemAssignment.find_or_create_by!(work_item:, project: issue.project) do |assignment|
        assignment.account = account
        assignment.provenance = "manual"
        assignment.locked = true
        assignment.default_execution = true
      end
    end

    def preserve_agent_run_history(work_item, issue)
      runs = AgentRun.where(issue:)
      conflict = runs.where.not(work_item_id: [ nil, work_item.id ]).first
      if conflict
        raise IdentityConflictError, "Agent run #{conflict.id} already belongs to another work item"
      end

      runs.where(work_item_id: nil).update_all(work_item_id: work_item.id, updated_at: Time.current)
    end

    def fetch_comments(issue)
      issue.project.client.issue_comments(issue.project.issue_target_repository, issue.github_number)
    end

    def serializable(record)
      return record if record.is_a?(Hash)
      return record.to_hash if record.respond_to?(:to_hash)
      return record.to_h if record.respond_to?(:to_h)

      record.attributes
    end
  end
end
