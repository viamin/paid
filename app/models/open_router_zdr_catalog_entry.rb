# frozen_string_literal: true

class OpenRouterZdrCatalogEntry < ApplicationRecord
  belongs_to :open_router_zdr_catalog
  belongs_to :llm_model

  validates :endpoint_count, numericality: { only_integer: true, greater_than: 0 }
end
