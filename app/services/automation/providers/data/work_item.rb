# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Lossless provider-neutral representation for tracker work. It is kept
      # alongside Data::Issue during the migration so existing GitHub issue
      # consumers retain their established contract.
      #
      # @spec UNIFIED-WORK-ITEMS-001
      class WorkItem < ::Data.define(
        :identity,
        :title,
        :body,
        :lifecycle,
        :author,
        :labels,
        :comments,
        :relations,
        :attachments,
        :assignments,
        :pull_request_links,
        :provider_extensions,
        :raw_payload,
        :created_at,
        :updated_at,
        :url
      )
        Identity = ::Data.define(:provider, :resource_type, :resource_id, :container_id)
        Actor = ::Data.define(:provider, :external_id, :login)
        Comment = ::Data.define(:identity, :author, :body, :created_at, :updated_at, :url)
        Relation = ::Data.define(:kind, :target, :raw_kind)
        Attachment = ::Data.define(:identity, :name, :url, :content_type, :size_bytes)
        Assignment = ::Data.define(:assignee, :provenance, :overridden_by, :overridden_at)
        LifecycleConflict = ::Data.define(:requested_state, :observed_state, :reason)
        Lifecycle = ::Data.define(:state, :raw_state, :mapping, :conflict)
        PullRequestLink = ::Data.define(:identity, :relationship, :url)
        Extension = ::Data.define(:provider, :type, :attributes)
        GithubExtension = ::Data.define(:node_id, :repository_id, :milestone_number)

        STATES = %i[open closed].freeze
        ASSIGNMENT_PROVENANCE = %i[provider paid inherited].freeze
        RELATION_KINDS = %i[blocks blocked_by relates_to parent child duplicate].freeze
        PULL_REQUEST_RELATIONSHIPS = %i[implements fixes relates_to].freeze
        LIFECYCLE_MAPPINGS = %i[direct mapped conflicted].freeze
      end
    end
  end
end
