# frozen_string_literal: true

module Knowledge
  module Decisions
    # Marks a decision record as superseded by a newer one.
    #
    # @example
    #   Knowledge::Decisions::Supersede.call(
    #     original: old_decision,
    #     superseding: new_decision
    #   )
    class Supersede
      attr_reader :original, :superseding

      def initialize(original:, superseding:)
        @original = original
        @superseding = superseding
      end

      def self.call(...)
        new(...).call
      end

      def call
        validate_records!

        original.with_lock do
          original.reload
          unless original.status.in?(%w[draft active])
            raise ArgumentError, "original must be draft or active to supersede"
          end

          original.update!(status: "superseded", superseded_by: superseding)

          superseding.decision_record_links.find_or_create_by!(
            linkable_type: "DecisionRecord",
            linkable_id: original.id.to_s,
            link_type: "reverts"
          )
        end

        original
      end

      private

      def validate_records!
        unless original.persisted? && superseding.persisted?
          raise ArgumentError, "original and superseding must be persisted records"
        end

        if original.equal?(superseding) || original.id == superseding.id
          raise ArgumentError, "original and superseding must be different records"
        end
      end
    end
  end
end
