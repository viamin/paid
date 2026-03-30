# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid do
  describe ".qdrant_api_key" do
    around do |example|
      original_env = ENV["QDRANT_API_KEY"]
      example.run
    ensure
      if original_env
        ENV["QDRANT_API_KEY"] = original_env
      else
        ENV.delete("QDRANT_API_KEY")
      end
    end

    it "returns the API key from ENV when set" do
      ENV["QDRANT_API_KEY"] = "test-key-123"
      allow(Rails.application.credentials).to receive(:dig).with(:qdrant, :api_key).and_return(nil)

      expect(described_class.qdrant_api_key).to eq("test-key-123")
    end

    it "prefers credentials over ENV" do
      ENV["QDRANT_API_KEY"] = "env-key"
      allow(Rails.application.credentials).to receive(:dig).with(:qdrant, :api_key).and_return("cred-key")

      expect(described_class.qdrant_api_key).to eq("cred-key")
    end

    it "returns nil in non-production without any key" do
      ENV.delete("QDRANT_API_KEY")
      allow(Rails.application.credentials).to receive(:dig).with(:qdrant, :api_key).and_return(nil)

      expect(described_class.qdrant_api_key).to be_nil
    end

    it "raises in production when both credentials and ENV are blank" do
      ENV.delete("QDRANT_API_KEY")
      allow(Rails.application.credentials).to receive(:dig).with(:qdrant, :api_key).and_return(nil)
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      expect { described_class.qdrant_api_key }
        .to raise_error(RuntimeError, /QDRANT_API_KEY is required in production/)
    end

    it "does not allow ENV fallback in production" do
      ENV["QDRANT_API_KEY"] = "env-key"
      allow(Rails.application.credentials).to receive(:dig).with(:qdrant, :api_key).and_return(nil)
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      expect { described_class.qdrant_api_key }
        .to raise_error(RuntimeError, /QDRANT_API_KEY is required in production/)
    end
  end
end
