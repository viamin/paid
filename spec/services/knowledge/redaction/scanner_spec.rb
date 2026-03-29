# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Redaction::Scanner do
  subject(:scanner) { described_class.new }

  describe "#scan" do
    it "returns empty array for nil input" do
      expect(scanner.scan(nil)).to eq([])
    end

    it "returns empty array for empty string" do
      expect(scanner.scan("")).to eq([])
    end

    it "returns empty array for clean text" do
      expect(scanner.scan("def hello_world; end")).to eq([])
    end

    context "with API keys" do
      it "detects api_key = 'value' patterns" do
        text = 'API_KEY = "sk_live_abcdef1234567890abcd"'
        matches = scanner.scan(text)
        expect(matches.size).to eq(1)
        expect(matches.first.pattern).to eq(:api_key)
      end

      it "detects api-key: value patterns" do
        text = 'api-key: ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        matches = scanner.scan(text)
        expect(matches.size).to eq(1)
        expect(matches.first.pattern).to eq(:api_key)
      end
    end

    context "with AWS keys" do
      it "detects AKIA-prefixed keys" do
        text = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern)
        expect(patterns).to include(:aws_key)
      end
    end

    context "with GitHub tokens" do
      it "detects ghp_ tokens" do
        text = "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern)
        expect(patterns).to include(:github_token)
      end

      it "detects ghs_ tokens" do
        text = "token: ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern)
        expect(patterns).to include(:github_token)
      end
    end

    context "with JWTs" do
      it "detects JWT tokens" do
        text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        matches = scanner.scan(text)
        expect(matches.first.pattern).to eq(:jwt)
      end
    end

    context "with passwords" do
      it "detects password = 'value' patterns" do
        text = "password = 'super_secret_123'"
        matches = scanner.scan(text)
        expect(matches.first.pattern).to eq(:password)
      end

      it "detects secret: 'value' patterns" do
        text = 'secret: "my_secret_value"'
        matches = scanner.scan(text)
        expect(matches.first.pattern).to eq(:password)
      end
    end

    context "with emails" do
      it "detects email addresses" do
        text = "contact: user@example.com for details"
        matches = scanner.scan(text)
        expect(matches.first.pattern).to eq(:email)
      end
    end

    context "with connection strings" do
      it "detects postgres connection strings" do
        text = 'DATABASE_URL=postgres://user:pass@host:5432/db'
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern)
        expect(patterns).to include(:connection_string)
      end

      it "detects redis connection strings" do
        text = "REDIS_URL=redis://localhost:6379/0"
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern)
        expect(patterns).to include(:connection_string)
      end

      it "detects mongodb connection strings" do
        text = "MONGO_URI=mongodb://admin:pass@mongo:27017/app"
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern)
        expect(patterns).to include(:connection_string)
      end
    end

    context "with private keys" do
      it "detects RSA private key headers" do
        text = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCA..."
        matches = scanner.scan(text)
        expect(matches.first.pattern).to eq(:private_key)
      end

      it "detects generic private key headers" do
        text = "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBg..."
        matches = scanner.scan(text)
        expect(matches.first.pattern).to eq(:private_key)
      end
    end

    context "with false positives" do
      it "does not flag key: :symbol as api_key" do
        text = "config = { key: :symbol, other: :value }"
        matches = scanner.scan(text)
        expect(matches).to be_empty
      end

      it "does not flag short key values" do
        text = 'api_key = "short"'
        matches = scanner.scan(text)
        expect(matches).to be_empty
      end

      it "does not flag regular method definitions" do
        text = "def password_reset_url; end"
        matches = scanner.scan(text)
        expect(matches).to be_empty
      end
    end

    context "with multiple patterns" do
      it "detects all patterns in mixed content" do
        text = <<~TEXT
          DATABASE_URL=postgres://user:pass@host/db
          API_KEY="sk_live_abcdefghijklmnopqrst"
          admin@example.com
        TEXT
        matches = scanner.scan(text)
        patterns = matches.map(&:pattern).uniq
        expect(patterns).to include(:connection_string, :api_key, :email)
      end
    end

    it "returns matches sorted by offset" do
      text = "admin@test.com and api_key=ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      matches = scanner.scan(text)
      offsets = matches.map(&:offset)
      expect(offsets).to eq(offsets.sort)
    end
  end

  describe ".scan" do
    it "delegates to instance" do
      text = "password = 'secret123'"
      expect(described_class.scan(text).size).to eq(1)
    end
  end
end
