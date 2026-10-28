# frozen_string_literal: true

module OpenrouterZdr
  class EligibleModels
    Result = Struct.new(:models, :last_successful_at, :unavailable, :last_error, keyword_init: true) do
      def unavailable? = unavailable

      def freshness
        return :unavailable if unavailable?
        return :unverified if last_successful_at.nil?

        :fresh
      end
    end

    def self.call # @spec FREE-MODEL-SYNC-013
      state = OpenrouterZdrCatalogState.current
      Result.new(models: LlmModel.active.openrouter_zdr_eligible.order(Arel.sql("family ASC NULLS LAST")).by_capability,
        last_successful_at: state.last_successful_at, unavailable: state.unavailable?, last_error: state.last_error)
    end
  end
end
