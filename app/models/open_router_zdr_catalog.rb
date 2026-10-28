# frozen_string_literal: true

class OpenRouterZdrCatalog < ApplicationRecord
  has_many :entries, class_name: "OpenRouterZdrCatalogEntry", dependent: :destroy
  has_many :llm_models, through: :entries

  def self.current
    find_or_create_by!(id: 1)
  rescue ActiveRecord::RecordNotUnique
    find(1)
  end

  # @spec FREE-MODEL-SYNC-013
  def eligible_models
    LlmModel.active.joins(:open_router_zdr_catalog_entries)
      .where(open_router_zdr_catalog_entries: { open_router_zdr_catalog_id: id })
      .distinct
  end
end
