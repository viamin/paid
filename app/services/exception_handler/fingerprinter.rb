# frozen_string_literal: true

module ExceptionHandler
  # Generates a stable fingerprint for an exception by normalizing the class,
  # message, and backtrace into a SHA-256 digest. Identical root causes produce
  # the same fingerprint even when dynamic values (IDs, timestamps, paths) vary.
  class Fingerprinter
    def self.call(exception:, subsystem:)
      new(exception: exception, subsystem: subsystem).call
    end

    def initialize(exception:, subsystem:)
      @exception = exception
      @subsystem = subsystem
    end

    def call
      Digest::SHA256.hexdigest(canonical_string)[0, 32]
    end

    private

    def canonical_string
      [
        @subsystem,
        @exception.class.name,
        normalize_message(@exception.message),
        normalize_backtrace(@exception.backtrace)
      ].join("\n")
    end

    def normalize_message(message)
      return "" if message.nil?

      message
        .gsub(/\b[0-9a-f]{8,}\b/i, "<ID>")
        .gsub(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[^\s]*/, "<TIMESTAMP>")
        .gsub(%r{/tmp/[^\s:]+}, "<TMPPATH>")
        .gsub(/\d+/, "<N>")
        .strip
    end

    def normalize_backtrace(backtrace)
      return "" if backtrace.nil?

      backtrace
        .first(5)
        .map { |line| normalize_backtrace_line(line) }
        .join("\n")
    end

    def normalize_backtrace_line(line)
      line
        .gsub(%r{/[\w./+-]+/gems/}, "<GEMS>/")
        .gsub(/:\d+:in/, ":<N>:in")
    end
  end
end
