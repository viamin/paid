# frozen_string_literal: true

module Automation
  module Providers
    module Data
      PullRequestRelationship = ::Data.define(:identity, :relation, :url)
    end
  end
end
