# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Stable identity for a resource owned by an external work-item provider.
      ProviderIdentity = ::Data.define(:provider, :resource_type, :external_id, :container_id, :url)
    end
  end
end
