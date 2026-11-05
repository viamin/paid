# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Stable provider-scoped identity. A provider identifier is never
      # meaningful without its resource/container scope.
      WorkItemIdentity = ::Data.define(:provider, :resource, :external_id, :display_id)

      # Assignment provenance distinguishes provider truth from a Paid override.
      Assignment = ::Data.define(:principal, :provenance, :overridden)

      # A typed link to another work item. The provider payload remains on the
      # containing work item for provider-specific relationship details.
      Relation = ::Data.define(:kind, :target)

      Attachment = ::Data.define(:id, :name, :url, :content_type)

      # A work item may be the pull request itself or reference a separate PR.
      PullRequestLink = ::Data.define(:provider, :resource, :number, :url, :relationship)

      # Records how a provider lifecycle value mapped to the normalized state.
      class LifecycleMapping < ::Data.define(:normalized, :provider_value, :conflict)
        def conflict? = conflict.present?
      end

      # Provider-neutral snapshot for new unified-work-item entry points.
      # Existing Data::Issue remains the compatibility contract for GitHub
      # issue automation while providers migrate incrementally.
      class WorkItem < ::Data.define(
        :identity,
        :title,
        :body,
        :lifecycle,
        :raw_lifecycle,
        :lifecycle_mapping,
        :author,
        :assignments,
        :labels,
        :comments,
        :relations,
        :attachments,
        :pull_requests,
        :provider_extensions,
        :raw_payload,
        :created_at,
        :updated_at,
        :closed_at,
        :url
      )
        LIFECYCLES = %i[open in_progress closed cancelled].freeze

        def self.from_issue(issue, provider:, resource:)
          identity = WorkItemIdentity.new(
            provider:, resource:, external_id: issue.number.to_s, display_id: issue.number.to_s
          )
          mapping = LifecycleMapping.new(
            normalized: issue.state, provider_value: issue.raw_state, conflict: nil
          )
          assignments = issue.assignee_logins.map do |principal|
            Assignment.new(principal:, provenance: :provider, overridden: false)
          end
          pull_requests = if issue.pull_request_number
            [ PullRequestLink.new(
              provider:, resource:, number: issue.pull_request_number, url: issue.url, relationship: :same_resource
            ) ]
          else
            []
          end

          new(
            identity:, title: issue.title, body: issue.body, lifecycle: issue.state,
            raw_lifecycle: issue.raw_state, lifecycle_mapping: mapping, author: issue.author_login,
            assignments:, labels: issue.labels, comments: [], relations: issue.dependencies.map {
              |dependency| Relation.new(
                kind: dependency.relation,
                target: WorkItemIdentity.new(
                  provider:, resource: dependency.target_repo, external_id: dependency.target_number.to_s,
                  display_id: dependency.target_number.to_s
                )
              )
            }, attachments: [], pull_requests:, provider_extensions: {}, raw_payload: {},
            created_at: issue.created_at, updated_at: issue.updated_at, closed_at: issue.closed_at, url: issue.url
          )
        end
      end
    end
  end
end
