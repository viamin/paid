# frozen_string_literal: true

module LayeredVerification
  module ReviewPackages
    # A stable, bounded page over append-only review packages.
    # @spec LAYERED-VERIFY-023
    class Page
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      Result = Data.define(:records, :next_cursor)

      def self.call(...) = new(...).call

      def initialize(relation:, limit: DEFAULT_LIMIT, cursor: nil)
        @relation = relation
        @limit = validate_limit(limit)
        @cursor = validate_cursor(cursor)
      end

      def call
        records = scoped_relation.limit(limit + 1).to_a
        page_records = records.first(limit)
        Result.new(records: page_records, next_cursor: records.size > limit ? page_records.last.id : nil)
      end

      private

      attr_reader :relation, :limit, :cursor

      def scoped_relation
        scope = relation.order(:id)
        cursor ? scope.where("id > ?", cursor) : scope
      end

      def validate_limit(value)
        return value if value.is_a?(Integer) && value.between?(1, MAX_LIMIT)

        raise ArgumentError, "limit must be an integer between 1 and #{MAX_LIMIT}"
      end

      def validate_cursor(value)
        return if value.nil?
        return value if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "cursor must be a positive integer"
      end
    end
  end
end
