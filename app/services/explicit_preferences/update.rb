# frozen_string_literal: true

module ExplicitPreferences
  # @spec FACET-CONFIDENCE-007
  class Update
    def self.call(...) = new(...).call

    def initialize(preference:, actor:, statement:, explicit:, scope_confirmed:)
      @preference = preference
      @actor = actor
      @statement = statement.to_s.strip
      @explicit = explicit
      @scope_confirmed = scope_confirmed
    end

    def call
      validate_confirmation!
      preference.update!(statement:, recorded_by: actor)
      preference
    end

    private

    attr_reader :actor, :explicit, :preference, :scope_confirmed, :statement

    def validate_confirmation!
      raise ArgumentError, "An explicit user statement is required" unless explicit
      raise ArgumentError, "An explicit or clarified scope is required" unless scope_confirmed
    end
  end
end
