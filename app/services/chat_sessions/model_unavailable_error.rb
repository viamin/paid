# frozen_string_literal: true

module ChatSessions
  # Raised when a consistent catalog snapshot contains no eligible chat model.
  # @spec ONBOARD-CHAT-014
  class ModelUnavailableError < ArgumentError
    attr_reader :rejection_reasons

    def initialize(runner:, rejection_reasons:)
      @rejection_reasons = rejection_reasons.map(&:to_sym).freeze
      super("No compatible Low chat model is available for #{runner.display_name}. #{guidance}")
    end

    private

    def guidance
      case rejection_reasons.first
      when :catalog_empty then "The provider catalog is empty; refresh the catalog or contact your administrator."
      when :runner_incompatible then "Available catalog models are not compatible with this runner's authentication mode or installed CLI."
      when :capability_mismatch then "Available catalog models do not support chat tools."
      when :unavailable then "All compatible models are currently unavailable; retry after availability checks refresh."
      when :verified_model_restriction then "Your verified-model settings exclude every compatible model."
      when :operator_policy then "Operator or project policy excludes every compatible model."
      when :low_tier_unavailable then "No compatible Low-tier model is configured for this provider."
      else "Check the catalog, API availability, verified-model settings, and operator policy."
      end
    end
  end
end
