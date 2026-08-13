# frozen_string_literal: true

require "spec_helper"
require_relative "../../config/worktree_database_names"

RSpec.describe Paid::WorktreeDatabaseNames do
  around do |example|
    original_env = ENV.to_hash
    example.run
  ensure
    ENV.replace(original_env)
  end

  describe ".development_primary_name" do
    it "returns an explicit override when it is identifier-safe" do
      ENV["PAID_DEVELOPMENT_DATABASE"] = "PaidDevelopment_123"

      expect(described_class.development_primary_name).to eq("PaidDevelopment_123")
    end

    it "raises for an explicit override with unsafe characters" do
      ENV["PAID_DEVELOPMENT_DATABASE"] = "x'; DROP DATABASE paid_production; --"

      expect { described_class.development_primary_name }
        .to raise_error(ArgumentError, /Invalid database name/)
    end

    it "raises for an explicit override longer than PostgreSQL allows" do
      ENV["PAID_DEVELOPMENT_DATABASE"] = "a" * 64

      expect { described_class.development_primary_name }
        .to raise_error(ArgumentError, /Invalid database name/)
    end
  end

  describe ".development_cable_name" do
    it "validates explicit overrides" do
      ENV["PAID_DEVELOPMENT_CABLE_DATABASE"] = "invalid-name"

      expect { described_class.development_cable_name }
        .to raise_error(ArgumentError, /PAID_DEVELOPMENT_CABLE_DATABASE/)
    end
  end

  describe ".test_name" do
    it "validates explicit overrides" do
      ENV["PAID_TEST_DATABASE"] = "invalid-name"

      expect { described_class.test_name }
        .to raise_error(ArgumentError, /PAID_TEST_DATABASE/)
    end
  end

  describe ".suffix" do
    it "validates explicit suffix overrides" do
      ENV["PAID_WORKTREE_DB_SUFFIX"] = "invalid-name"

      expect { described_class.suffix }
        .to raise_error(ArgumentError, /PAID_WORKTREE_DB_SUFFIX/)
    end
  end
end
