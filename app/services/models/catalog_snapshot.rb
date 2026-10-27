# frozen_string_literal: true

module Models
  # Coordinates catalog writers and readers so a selection cannot observe the
  # intermediate rows produced by a scheduled catalog refresh.
  # @spec MODEL-AVAILABILITY-008
  class CatalogSnapshot
    LOCK_ID = 4668

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
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock#{shared_suffix}(#{LOCK_ID})")
    end

    def shared_suffix
      "_shared" if mode == :shared
    end
  end
end
