# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpecDatabaseAvailability, :no_db do
  describe ".unavailable?" do
    it "treats a missing database as unavailable for dbless runs" do
      error = ActiveRecord::NoDatabaseError.new("missing")

      expect(described_class.unavailable?(error)).to be(true)
    end

    it "treats a disconnected database as unavailable for dbless runs" do
      error = ActiveRecord::ConnectionNotEstablished.new("down")

      expect(described_class.unavailable?(error)).to be(true)
    end

    it "does not swallow unrelated schema maintenance errors" do
      error = RuntimeError.new("boom")

      expect(described_class.unavailable?(error)).to be(false)
    end
  end
end
