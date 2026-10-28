# frozen_string_literal: true

module OpenrouterZdr
  class Catalog
    Snapshot = Struct.new(:models, :status, keyword_init: true) do
      delegate :fresh?, to: :status
    end

    # @spec OPENROUTER-ZDR-CATALOG-004
    # @spec OPENROUTER-ZDR-CATALOG-005
    def self.call
      Snapshot.new(models: EligibleModels.call, status: OpenrouterZdrCatalogStatus.current)
    end
  end
end
