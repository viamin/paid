# frozen_string_literal: true

class OpenrouterZdrCatalogState < ApplicationRecord
  SOURCE = "openrouter_zdr"

  validates :source, presence: true, uniqueness: true

  def self.current
    find_or_create_by!(source: SOURCE)
  rescue ActiveRecord::RecordNotUnique
    find_by!(source: SOURCE)
  end

  def unavailable?
    unavailable_at.present?
  end
end
