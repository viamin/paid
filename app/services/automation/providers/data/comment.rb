# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Provider-neutral conversation comment. Returned by comment-fetch
      # methods on both {Automation::Providers::RepositoryProvider} and
      # {Automation::Providers::WorkItemProvider}.
      #
      # - +id+ [Integer, String] Provider-local comment identifier.
      # - +author_login+ [String, nil] Author login, downcased.
      # - +body+ [String] Markdown body.
      # - +created_at+ [Time]
      # - +updated_at+ [Time, nil]
      # - +url+ [String, nil] Browser-viewable URL.
      Comment = ::Data.define(
        :id,
        :author_login,
        :body,
        :created_at,
        :updated_at,
        :url
      )
    end
  end
end
