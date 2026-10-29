# frozen_string_literal: true

module Runners
  # Resolves the privacy requirement that must survive route selection. A
  # project can raise the minimum and a runner declaration can raise it again;
  # neither input is permitted to lower the other.
  class EffectivePrivacyPolicy
    Result = Data.define(:project_requires_zdr, :runner_requires_zdr, :zdr_required, :provenance, :eligible) do
      def openrouter_enforced?
        provenance == "openrouter_enforced"
      end
    end

    def self.call(...) = new(...).call

    def initialize(project:, runner:, required_zdr: nil)
      @project = project
      @runner = runner
      @required_zdr = required_zdr
    end

    # @spec MODEL-POLICY-018
    def call
      required = project_requires_zdr || runner_requires_zdr || @required_zdr == true
      return Result.new(project_requires_zdr:, runner_requires_zdr:, zdr_required: false, provenance: "disabled", eligible: true) unless required

      Result.new(
        project_requires_zdr:,
        runner_requires_zdr:,
        zdr_required: true,
        provenance: provenance,
        eligible: eligible?
      )
    end

    private

    def project_requires_zdr
      @project&.respond_to?(:restricted?) && @project.restricted? == true
    end
    def runner_requires_zdr = @runner&.zero_data_retention? == true

    def provenance
      return "openrouter_enforced" if openrouter_enforced?
      return "user_declared" if runner_requires_zdr

      "unavailable"
    end

    def eligible?
      return true unless @runner
      return openrouter_enforced? if openrouter?

      runner_requires_zdr
    end

    def openrouter_enforced?
      openrouter? && @runner.openrouter_zdr_request_routing_supported?
    end

    def openrouter?
      @runner&.required_api_service_type == Runner::OPENROUTER_FREE_MODEL_PROVIDER
    end
  end
end
