# frozen_string_literal: true

module Paid
  module WorkerReadiness
    # Binds readiness to the source identity that existed before Rails loaded
    # application code. A second read after worker construction detects a boot
    # race instead of attesting source newer than the constants in memory.
    # @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-004
    class StartupIdentity
      class SourceChangedError < StandardError; end

      attr_reader :revision

      def self.capture(&reader)
        new(reader:, revision: reader.call)
      end

      def initialize(reader:, revision:)
        @reader = reader
        @revision = revision
      end

      def verify!
        return self if reader.call == revision

        raise SourceChangedError, "source changed while the Temporal worker was booting"
      end

      private

      attr_reader :reader
    end
  end
end
