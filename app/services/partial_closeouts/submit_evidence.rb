# frozen_string_literal: true

require "digest"

module PartialCloseouts
  # Records an operator's evidence against one exact human prerequisite. A
  # submission is intentionally not a scheduling release: evidence has to be
  # assessed by the bounded acceptance-audit path before ResolveEvidence can
  # resolve the prerequisite notification.
  # @spec PARTIAL-CLOSEOUT-030
  class SubmitEvidence
    Result = Data.define(:success, :error, :notification) do
      def success? = success
    end

    KINDS = %w[evaluation_report agent_run durable_artifact link].freeze

    def self.call(...) = new(...).call

    def initialize(notification:, actor:, criterion:, kind:, reference:, revision:, explanation:)
      @notification = notification
      @actor = actor
      @criterion = criterion.to_s.strip
      @kind = kind.to_s
      @reference = reference.to_s.strip
      @revision = revision.to_s.strip
      @explanation = explanation.to_s.strip
    end

    def call
      return failure("Select a current prerequisite.") unless prerequisite
      return failure("Select a supported evidence type.") unless KINDS.include?(kind)
      return failure("Evidence reference, revision, and explanation are required.") if [ reference, revision, explanation ].any?(&:blank?)

      notification.with_lock do
        return failure("This prerequisite is no longer awaiting evidence.") unless notification.active?

        notification.update!(metadata: notification.metadata.merge("prerequisites" => updated_prerequisites))
      end
      Result.new(success: true, error: nil, notification: notification)
    end

    private

    attr_reader :actor, :criterion, :explanation, :kind, :notification, :reference, :revision

    def prerequisites = Array(notification.metadata["prerequisites"])

    def prerequisite
      @prerequisite ||= prerequisites.find { |entry| entry.is_a?(Hash) && entry["criterion"] == criterion }
    end

    def updated_prerequisites
      prerequisites.map do |entry|
        next entry unless entry == prerequisite

        entry.merge(
          "status" => "submitted",
          "outcome" => "pending_validation",
          "evidence" => {
            "kind" => kind, "reference" => reference, "revision" => revision,
            "explanation" => explanation, "actor_id" => actor.id, "submitted_at" => Time.current.iso8601,
            "prerequisite_revision" => prerequisite_revision
          },
          "next_action" => "Run a bounded acceptance audit to validate this evidence. Dismissal releases scheduling but is not acceptance."
        )
      end
    end

    def failure(error) = Result.new(success: false, error: error, notification: notification)

    def prerequisite_revision
      Digest::SHA256.hexdigest(prerequisite.slice("criterion", "kind", "next_step", "prerequisite").to_json)
    end
  end
end
