# frozen_string_literal: true

require "pathname"

module LayeredVerification
  # Captures repository paths that declare an obligation's evidence boundary.
  # Unparseable references make the snapshot incomplete so callers fall back
  # to invalidation instead of guessing whether a later change overlaps it.
  # @spec LAYERED-VERIFY-019
  class ScopeSnapshot
    Snapshot = Data.define(:paths, :complete)

    def self.call(obligation)
      new(obligation).call
    end

    def initialize(obligation)
      @obligation = obligation
    end

    def call
      paths = references.filter_map { |reference| repository_path(reference) }
      Snapshot.new(paths.uniq.sort, correspondence_references.present? && paths.size == references.size)
    end

    private

    attr_reader :obligation

    def references
      @references ||= [ obligation.canonical_source_path, *correspondence_references ]
        .map(&:to_s).reject(&:blank?).uniq
    end

    def correspondence_references
      @correspondence_references ||= obligation.correspondence_claims
        .flat_map { |claim| [ claim.source_reference, claim.target_reference ] }
    end

    def repository_path(reference)
      raw_path = reference.split("#", 2).first.sub(/:\d+(?:-\d+)?\z/, "")
      return if raw_path.match?(%r{\A[a-z][a-z0-9+.-]*://}i) || raw_path.match?(/[\s\0]/)

      candidate = Pathname.new(raw_path)
      clean = candidate.cleanpath.to_s
      clean if !candidate.absolute? && clean != "." && clean != ".." && !clean.start_with?("../")
    rescue ArgumentError
      nil
    end
  end
end
