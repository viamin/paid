# frozen_string_literal: true

class OpenrouterZdrCatalog < ApplicationRecord
  CURRENT_KEY = "openrouter_zdr"

  validates :catalog_key, presence: true, uniqueness: true

  def self.current
    find_or_create_by!(catalog_key: CURRENT_KEY)
  end

  def available?
    unavailable_at.nil?
  end
end
