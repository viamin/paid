# frozen_string_literal: true

module Automation
  module Providers
    module Data
      # Typed provider-owned fields that have no provider-neutral equivalent.
      ProviderExtension = ::Data.define(:provider, :type, :attributes)
    end
  end
end
