# frozen_string_literal: true

module ExplicitPreferences
  # @spec FACET-CONFIDENCE-007
  class Delete
    def self.call(...) = new(...).call

    def initialize(preference:)
      @preference = preference
    end

    def call
      preference.destroy!
    end

    private

    attr_reader :preference
  end
end
