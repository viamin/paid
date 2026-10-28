# frozen_string_literal: true

class OpenrouterZdrCatalogRefresh < ApplicationRecord
  CATALOG_KEY = "openrouter_zdr".freeze

  validates :catalog_key, presence: true, uniqueness: true

  def self.current
    find_or_create_by!(catalog_key: CATALOG_KEY)
  end
end
