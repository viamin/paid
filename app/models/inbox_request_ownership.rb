# frozen_string_literal: true

class InboxRequestOwnership < ApplicationRecord
  belongs_to :project, optional: true

  validates :request_key, presence: true, uniqueness: true
  validates :entry_kind, presence: true
  validates :classification_state, presence: true,
    inclusion: { in: [ Inbox::PhaseOwnership::CLASSIFIED, Inbox::PhaseOwnership::UNKNOWN, Inbox::PhaseOwnership::PLATFORM ] }

  scope :phase_owned, -> { where.not(responsible_phase: nil) }
  scope :for_phases, ->(phases) { where(responsible_phase: Array(phases).map(&:to_s)) }

  def phase_owned?
    responsible_phase.present?
  end
end