# frozen_string_literal: true

# Links a feature intent to one issue in its tree (implementation issue or
# PR issue). Unique per issue so a branch belongs to at most one feature.
class FeatureIntentIssue < ApplicationRecord
  belongs_to :feature_intent
  belongs_to :issue

  validates :issue_id, uniqueness: true
end
