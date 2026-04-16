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
        :pull_request_number
      )
        STATES = %i[open closed].freeze
      end
    end
  end
end
