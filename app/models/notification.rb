# frozen_string_literal: true

class Notification < ApplicationRecord
  belongs_to :account
  belongs_to :user, optional: true
  belongs_to :subject, polymorphic: true, optional: true

  enum :severity, { info: 0, warning: 1, error: 2 }, validate: true

  validates :source, presence: true
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :undismissed, -> { where(dismissed_at: nil) }
  scope :unresolved, -> { where(resolved_at: nil) }
  scope :active, -> { undismissed.unresolved }
  scope :visible, -> { undismissed }
  scope :for_nav_section, ->(section) { where(nav_section: section) }
  scope :recent, -> { order(created_at: :desc) }

  NAV_SECTIONS = %w[dashboard projects agent_runs providers].freeze
end
