# frozen_string_literal: true

class ProjectDelegationMetric < ApplicationRecord
  EVENT_TYPES = %w[
    issue_started issue_completed inbox_decision material_reversal
    security_breach tenant_breach trust_breach evidence_missing
  ].freeze
  COHORTS = %w[pilot baseline].freeze

  belongs_to :project

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :cohort, inclusion: { in: COHORTS }
  validates :intent_revision, :acceptance_revision, :evidence_revision, :occurred_at, presence: true
end
