# frozen_string_literal: true

class OpenrouterZdrCatalogRefresh < ApplicationRecord
  CATALOG_NAME = "openrouter_zdr"
  STATUSES = %w[never successful unavailable].freeze

  validates :catalog_name, inclusion: { in: [ CATALOG_NAME ] }, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.current
    find_or_create_by!(catalog_name: CATALOG_NAME)
  end
end
