# frozen_string_literal: true

module LayeredVerification
  module Plans
    # A bounded, explicit check-selection record. Selection is supplied by the
    # coordinating agent; Rails validates the shape and keeps omissions visible.
    # @spec LAYERED-VERIFY-021
    class Build
      Plan = Data.define(:obligation_ids, :selected_checks, :exclusions)

      def self.call(...)
        new(...).call
      end

      def initialize(obligations:, checks:, exclusions: [])
        @obligations = obligations
        @checks = checks
        @exclusions = exclusions
      end

      def call
        Plan.new(obligation_ids: obligations.map(&:id), selected_checks: selected_checks, exclusions: normalized_exclusions)
      end

      private

      attr_reader :checks, :exclusions, :obligations

      def selected_checks
        checks.map { |check| normalize_check(check) }
      end

      def normalize_check(check)
        value = check.to_h.symbolize_keys
        required = %i[producer fit inputs assumptions resources limitations]
        missing = required.reject { |key| value[key].present? || value[key] == [] || value[key] == {} }
        raise ArgumentError, "verification plan check is missing: #{missing.join(', ')}" if missing.any?
        raise ArgumentError, "unknown verification producer: #{value[:producer]}" unless LayeredVerificationCheckResult::PRODUCERS.include?(value[:producer])

        value.slice(*required)
      end

      def normalized_exclusions
        exclusions.map do |exclusion|
          value = exclusion.to_h.symbolize_keys
          raise ArgumentError, "verification plan exclusion requires producer and reason" if value[:producer].blank? || value[:reason].blank?

          value.slice(:producer, :reason)
        end
      end
    end
  end
end
