# frozen_string_literal: true

module Automation
  module Providers
    module Data
      Relation = ::Data.define(:type, :target, :raw_type)
    end
  end
end
