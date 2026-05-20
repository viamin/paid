# frozen_string_literal: true

class ProjectConventionOverride < ApplicationRecord
  MODES = %w[apply warn ignore].freeze

  belongs_to :project

  before_validation :assign_category
  before_validation :sync_enabled_from_mode

  validates :category, presence: true, length: { maximum: 100 }
  validates :key, presence: true, length: { maximum: 100 }, uniqueness: { scope: :project_id }
  validates :enabled, inclusion: { in: [ true, false ] }
  validates :mode, presence: true, inclusion: { in: MODES }
  validate :value_is_object

  scope :enabled, -> { where(enabled: true) }
  scope :disabled, -> { where(enabled: false) }

  def apply?
    mode == "apply"
  end

  def warn?
    mode == "warn"
  end

  def ignore?
    mode == "ignore"
  end

  private

  def assign_category
    self.category = ProjectConventions::Catalog.category_for(key) if key.present?
  end

  def sync_enabled_from_mode
    self.mode = enabled == false ? "ignore" : "apply" if mode.blank?
    self.enabled = !ignore? if mode.present?
  end

  def value_is_object
    errors.add(:value, "must be an object") unless value.is_a?(Hash)
  end
end
