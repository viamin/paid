# frozen_string_literal: true

module PartialCloseouts
  # Normalizes the single occurrence represented by prerequisite notifications
  # created before occurrence-level metadata was introduced.
  # @spec PARTIAL-CLOSEOUT-033
  class PrerequisiteOccurrences
    def self.for(notification)
      occurrences = notification.metadata["prerequisites"]
      return Array(occurrences) if notification.metadata.key?("prerequisites")

      legacy_occurrence(notification).then { |occurrence| occurrence ? [ occurrence ] : [] }
    end

    def self.upgrade!(notification)
      return if notification.metadata.key?("prerequisites")

      occurrence = legacy_occurrence(notification)
      return unless occurrence

      occurrence["source_revision"] = Assessment.source_revision_for(notification.subject)
      notification.update!(metadata: notification.metadata.merge("prerequisites" => [ occurrence ]))
    end

    def self.legacy_occurrence(notification)
      identity = notification.metadata["prerequisite_identity"].to_s
      return if identity.blank?

      { "identity" => identity, "criterion" => notification.description.presence || notification.title.presence || "Operator prerequisite",
        "references" => Array(notification.metadata["references"]) }
    end
    private_class_method :legacy_occurrence
  end
end
