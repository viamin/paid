# frozen_string_literal: true

class OpenrouterZdrCatalogState < ApplicationRecord
  def self.instance
    first_or_create!
  end

  def available?
    unavailable_at.nil?
  end

  def unavailable?
    !available?
  end
end
