# frozen_string_literal: true

module HealthChecks
  class Check
    class << self
      attr_writer :scope

      def call(subject)
        new(subject).call
      end

      def scope
        @scope
      end

      def network?
        true
      end
    end

    def initialize(subject)
      @subject = subject
    end

    private

    attr_reader :subject

    def finding(severity:, message:)
      [
        Finding.new(
          check: self.class.name,
          scope: self.class.scope,
          severity: severity,
          message: message
        )
      ]
    end
  end
end
