# frozen_string_literal: true

class OpenrouterZdrCatalog < ApplicationRecord
  CURRENT_KEY = "openrouter_zdr"
  SETUP_STALE_AFTER = 24.hours

  validates :catalog_key, presence: true, uniqueness: true

  def self.current
    find_or_create_by!(catalog_key: CURRENT_KEY)
  end

  def available?
    unavailable_at.nil?
  end

  # The setup flow never treats last-known data as a fresh eligibility
  # assertion. A daily sync normally keeps this ready; each other state is
  # deliberately rendered as non-selectable until the catalog is current.
  # @spec RUNNER-MODEL-OPTIONS-009
  def setup_state
    return "unavailable" unless available?
    return "loading" if last_successful_at.nil?
    return "stale" if last_successful_at < SETUP_STALE_AFTER.ago
    return "empty" unless OpenrouterZdr::EligibleModels.models.exists?

    "ready"
  end

  def ready_for_setup?
    setup_state == "ready"
  end
end
