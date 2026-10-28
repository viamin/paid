# frozen_string_literal: true

class OpenrouterZdrModel < ApplicationRecord
  validates :model_id, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
end
