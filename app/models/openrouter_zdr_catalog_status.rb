# frozen_string_literal: true

class OpenrouterZdrCatalogStatus < ApplicationRecord
  SOURCE = "openrouter_zdr".freeze
  STATUSES = %w[available unavailable].freeze

  validates :source, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.current
    find_or_create_by!(source: SOURCE) { |record| record.status = "unavailable" }
  rescue ActiveRecord::RecordNotUnique
    find_by!(source: SOURCE)
  end

  def available?
    status == "available"
  end
end
