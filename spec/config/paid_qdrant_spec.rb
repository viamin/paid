# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid do
  describe ".embedding_dimensions" do
    around do |example|
      original = ENV["EMBEDDING_DIMENSIONS"]
      example.run
    ensure
      if original.nil?
        ENV.delete("EMBEDDING_DIMENSIONS")
      else
        ENV["EMBEDDING_DIMENSIONS"] = original
      end
    end

    it "defaults to 3072 when env var is unset" do
      ENV.delete("EMBEDDING_DIMENSIONS")
      expect(described_class.embedding_dimensions).to eq(3072)
    end

    it "defaults to 3072 when env var is blank" do
      ENV["EMBEDDING_DIMENSIONS"] = "  "
      expect(described_class.embedding_dimensions).to eq(3072)
    end

    it "parses a valid integer" do
      ENV["EMBEDDING_DIMENSIONS"] = "1536"
      expect(described_class.embedding_dimensions).to eq(1536)
    end

    it "raises on non-numeric value" do
      ENV["EMBEDDING_DIMENSIONS"] = "abc"
      expect { described_class.embedding_dimensions }.to raise_error(ArgumentError, /must be a positive integer/)
    end

    it "raises on zero" do
      ENV["EMBEDDING_DIMENSIONS"] = "0"
      expect { described_class.embedding_dimensions }.to raise_error(ArgumentError, /must be a positive integer/)
    end

    it "raises on negative value" do
      ENV["EMBEDDING_DIMENSIONS"] = "-5"
      expect { described_class.embedding_dimensions }.to raise_error(ArgumentError, /must be a positive integer/)
    end
  end
end
