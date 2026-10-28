# frozen_string_literal: true

class OpenrouterZdrCatalogStatus < ApplicationRecord
  CATALOG_KEY = "openrouter_zdr".freeze
  STATUSES = %w[verified unavailable].freeze

  validates :catalog_key, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.current
    find_or_create_by!(catalog_key: CATALOG_KEY)
  end

  def fresh?
    status == "verified"
  end
end
