# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Complete, provider-neutral work-item snapshot. The legacy Issue shape
      # remains supported while providers adopt this richer contract.
      # @spec UNIFIED-WORK-ITEMS-001
      WorkItem = ::Data.define(
        :identity,
        :title,
        :body,
        :state,
        :raw_state,
        :author_identity,
        :labels,
        :comments,
        :relations,
        :attachments,
        :assignment,
        :lifecycle,
        :pull_request_relationships,
        :provider_extension,
        :raw_payload,
        :created_at,
        :updated_at,
        :closed_at,
        :url
      )
    end
  end
end
