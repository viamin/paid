# frozen_string_literal: true

class MarketplaceEntryRule < ApplicationRecord
  MODES = %w[automatic team_default].freeze

  belongs_to :marketplace_entry

  validates :mode, presence: true, inclusion: { in: MODES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :conditions_is_object

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(:position, :id) }

  private

  def conditions_is_object
    errors.add(:conditions, "must be an object") unless conditions.is_a?(Hash)
  end
end
