# frozen_string_literal: true

module Models
  # Serializes catalog writers and readers that combine catalog rows with
  # availability evidence. A transaction-scoped advisory lock makes a reader
  # wait for an in-progress refresh instead of combining two catalog versions.
  # @spec MODEL-AVAILABILITY-008
  class CatalogSnapshot
    LOCK_KEY = 4_668

    def self.read(&) = new.read(&)
    def self.refresh(&) = new.refresh(&)

    def read
      within_snapshot { yield }
    end

    def refresh
      within_snapshot { yield }
    end

    private

    def within_snapshot
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
        yield
      end
    end
  end
end
