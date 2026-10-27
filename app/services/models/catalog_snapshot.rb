# frozen_string_literal: true

module Models
  # Coordinates catalog writers and readers so a selection cannot observe the
  # intermediate rows produced by a scheduled catalog refresh.
  # @spec MODEL-AVAILABILITY-008
  class CatalogSnapshot
    LOCK_ID = 4668
    EXCLUSIVE_LOCK_SQL = "SELECT pg_advisory_xact_lock(#{LOCK_ID})"
    SHARED_LOCK_SQL = "SELECT pg_advisory_xact_lock_shared(#{LOCK_ID})"

    def self.refresh(&) = new(:exclusive).with_lock(&)
    def self.consistent_read(&) = new(:shared).with_lock(&)

    def initialize(mode)
      @mode = mode
    end

    def with_lock
      ActiveRecord::Base.transaction(requires_new: true) do
        acquire_lock
        yield
      end
    end

    private

    attr_reader :mode

    def acquire_lock
      ActiveRecord::Base.connection.execute(mode == :shared ? SHARED_LOCK_SQL : EXCLUSIVE_LOCK_SQL)
    end
  end
end
