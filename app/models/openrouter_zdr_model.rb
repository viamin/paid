# frozen_string_literal: true

class OpenrouterZdrModel < ApplicationRecord
  validates :model_id, presence: true, uniqueness: true
  validates :endpoint_count, numericality: { greater_than: 0 }
end
