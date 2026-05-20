# frozen_string_literal: true

class ProjectConventionOverride < ApplicationRecord
  belongs_to :project

  validates :key, presence: true, length: { maximum: 100 }, uniqueness: { scope: :project_id }
  validates :enabled, inclusion: { in: [ true, false ] }

  scope :enabled, -> { where(enabled: true) }
  scope :disabled, -> { where(enabled: false) }
end
