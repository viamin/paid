# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Provider-neutral work-item snapshot. Returned by
      # {Automation::Providers::WorkItemProvider#fetch_issue} and
      # {Automation::Providers::WorkItemProvider#list_issues}.
      #
      # Fields:
      # - +number+ [Integer, String] Provider-local identifier. Integer for
      #   GitHub/GitLab; String for Jira/Linear-style keys.
      # - +title+ [String]
      # - +body+ [String, nil]
      # - +state+ [Symbol] One of {STATES}.
      # - +raw_state+ [String, nil] Provider-native state name for audit.
      # - +author_login+ [String, nil]
      # - +assignee_logins+ [Array<String>]
      # - +labels+ [Array<String>]
      # - +dependencies+ [Array<Dependency>] Structured blocker/relates-to
      #   edges exposed by the provider. Policy code also consults
      #   text-parsed dependencies; this field covers only what the
      #   provider models natively.
      # - +created_at+ [Time]
      # - +updated_at+ [Time]
      # - +closed_at+ [Time, nil]
      # - +url+ [String, nil]
      # - +pull_request_number+ [Integer, String, nil] Set when the provider
      #   exposes issues and PRs as a single entity (GitHub) and the item
      #   is actually a PR. Nil for providers where issues and PRs are
      #   distinct resources.
      class Issue < ::Data.define(
        :number,
        :title,
        :body,
        :state,
        :raw_state,
        :author_login,
        :assignee_logins,
        :labels,
        :dependencies,
        :created_at,
        :updated_at,
        :closed_at,
        :url,
        :pull_request_number,
        :raw_payload
      )
        STATES = %i[open closed].freeze

        # Provider relation spellings normalized onto the unified relation
        # kinds. Every other provider-native kind is carried through
        # unchanged so no provider meaning is discarded.
        RELATION_KIND_ALIASES = { related_to: :relates_to, duplicates: :duplicate }.freeze

        # Additive compatibility field: existing provider call sites retain
        # their established keyword shape while adapters can preserve the
        # source payload for conversion into the richer WorkItem contract.
        def initialize(number:, title:, body:, state:, raw_state:, author_login:, assignee_logins:, labels:, dependencies:,
          created_at:, updated_at:, closed_at:, url:, pull_request_number:, raw_payload: nil)
          super
        end

        # @spec UNIFIED-WORK-ITEMS-001
        def to_work_item(provider: :github, container_id: nil)
          WorkItem.new(
            identity: WorkItem::Identity.new(provider:, resource_type: :issue, resource_id: number.to_s, container_id:),
            title:, body:,
            lifecycle: WorkItem::Lifecycle.new(state:, raw_state:, mapping: :direct, conflict: nil),
            author: author_login && WorkItem::Actor.new(provider:, external_id: author_login, login: author_login),
            labels:, comments: [], relations: dependencies.map { |dependency| build_relation(dependency) },
            attachments: [],
            assignments: assignee_logins.map { |login|
              WorkItem::Assignment.new(
                assignee: WorkItem::Actor.new(provider:, external_id: login, login:),
                provenance: :provider, overridden_by: nil, overridden_at: nil
              )
            },
            pull_request_links: pull_request_number ? [ WorkItem::PullRequestLink.new(
              identity: WorkItem::Identity.new(provider:, resource_type: :pull_request, resource_id: pull_request_number.to_s, container_id:),
              relationship: :relates_to, url:
            ) ] : [],
            provider_extensions: [], raw_payload: raw_payload || {}, created_at:, updated_at:, url:
          )
        end

        private

        # A relation keeps the provider-native kind beside the unified kind it
        # maps onto, so the normalization stays auditable.
        def build_relation(dependency)
          raw_kind = dependency.relation

          WorkItem::Relation.new(
            kind: RELATION_KIND_ALIASES.fetch(raw_kind, raw_kind),
            target: dependency,
            raw_kind:
          )
        end
      end
    end
  end
end
