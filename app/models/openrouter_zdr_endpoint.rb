# frozen_string_literal: true

class OpenrouterZdrEndpoint < ApplicationRecord
  scope :active, -> { where.not(last_seen_at: nil) }

  validates :model_id, :endpoint_name, :last_seen_at, presence: true
end
