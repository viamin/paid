# frozen_string_literal: true

class OpenrouterZdrSync < ApplicationRecord
  STATUSES = %w[available unavailable].freeze

  validates :status, inclusion: { in: STATUSES }

  def self.current
    find_or_create_by!(id: 1)
  end

  def available?
    status == "available"
  end
end
