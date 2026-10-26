# frozen_string_literal: true

module LayeredVerification
  module Plans
    # A plan is an auditable request contract, not a semantic scoring engine.
    # Semantic check selection is supplied by the bounded agent/human request;
    # this class verifies its shape and makes every omitted capability visible.
    # @spec LAYERED-VERIFY-021
    class Build
      Check = Data.define(:producer, :fit, :required_inputs, :assumptions, :resource_expectations, :limitations)
      Result = Data.define(:selected_checks, :omissions, :residual_gaps)

      def self.call(...) = new(...).call

      def initialize(checks:, omissions:, residual_gaps:)
        @checks = checks
        @omissions = omissions
        @residual_gaps = residual_gaps
      end

      def call
        Result.new(selected_checks: checks.map { |check| build_check(check) }, omissions: normalized_omissions, residual_gaps: Array(residual_gaps).map(&:to_s))
      end

      private

      attr_reader :checks, :omissions, :residual_gaps

      def build_check(check)
        values = check.to_h.stringify_keys
        producer = values.fetch("producer")
        raise ArgumentError, "unsupported verification producer: #{producer}" unless LayeredVerificationCheckResult::PRODUCERS.include?(producer)

        Check.new(
          producer:,
          fit: values.fetch("fit").to_s,
          required_inputs: Array(values["required_inputs"]).map(&:to_s),
          assumptions: Array(values["assumptions"]).map(&:to_s),
          resource_expectations: values.fetch("resource_expectations", {}).to_h,
          limitations: values.fetch("limitations").to_s
        ).tap { |result| raise ArgumentError, "check limitations are required" if result.limitations.blank? }
      end

      def normalized_omissions
        Array(omissions).map do |omission|
          values = omission.to_h.stringify_keys
          producer = values.fetch("producer").to_s
          reason = values.fetch("reason").to_s
          raise ArgumentError, "omission producer is required" if producer.blank?
          raise ArgumentError, "omission reason is required" if reason.blank?

          { "producer" => producer, "reason" => reason }
        end
      end
    end
  end
end
