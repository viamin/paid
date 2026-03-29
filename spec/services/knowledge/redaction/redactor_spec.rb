# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Redaction::Redactor do
  describe ".call" do
    it "returns clean text unchanged when no patterns match" do
      result = described_class.call(text: "def hello; puts 'world'; end")
      expect(result.clean_text).to eq("def hello; puts 'world'; end")
      expect(result.redactions).to be_empty
      expect(result.redacted?).to be false
      expect(result.fully_redacted?).to be false
    end

    it "replaces API keys with typed placeholders" do
      text = 'config.api_key = "sk_live_abcdefghijklmnopqrst"'
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:api_key]")
      expect(result.clean_text).not_to include("sk_live_abcdefghijklmnopqrst")
      expect(result.redacted?).to be true
    end

    it "replaces AWS keys with typed placeholders" do
      text = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:aws_key]")
      expect(result.clean_text).not_to include("AKIAIOSFODNN7EXAMPLE")
    end

    it "replaces GitHub tokens with typed placeholders" do
      text = "GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:github_token]")
    end

    it "replaces emails with typed placeholders" do
      text = "Contact admin@example.com for support"
      result = described_class.call(text: text)
      expect(result.clean_text).to eq("Contact [REDACTED:email] for support")
      expect(result.redactions.size).to eq(1)
    end

    it "replaces connection strings with typed placeholders" do
      text = "DATABASE_URL=postgres://user:pass@host:5432/mydb"
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:connection_string]")
      expect(result.clean_text).not_to include("user:pass")
    end

    it "replaces private key headers with typed placeholders" do
      text = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA..."
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:private_key]")
    end

    it "replaces passwords with typed placeholders" do
      text = 'password = "super_secret_password_123"'
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:password]")
      expect(result.clean_text).not_to include("super_secret_password_123")
    end

    it "replaces JWTs with typed placeholders" do
      text = "token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:jwt]")
    end

    it "handles multiple redactions in one text" do
      text = <<~TEXT
        DATABASE_URL=postgres://user:pass@host/db
        ADMIN_EMAIL=admin@example.com
      TEXT
      result = described_class.call(text: text)
      expect(result.clean_text).to include("[REDACTED:connection_string]")
      expect(result.clean_text).to include("[REDACTED:email]")
      expect(result.redactions.size).to be >= 2
    end

    it "handles nil input" do
      result = described_class.call(text: nil)
      expect(result.clean_text).to eq("")
      expect(result.redactions).to be_empty
    end

    it "preserves non-sensitive surrounding text" do
      text = "before admin@test.com after"
      result = described_class.call(text: text)
      expect(result.clean_text).to eq("before [REDACTED:email] after")
    end

    context "with fully_redacted?" do
      it "returns true when most content is sensitive" do
        text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
        result = described_class.call(text: text)
        expect(result.fully_redacted?).to be true
      end

      it "returns false when only part of content is sensitive" do
        text = "This is a long paragraph of normal text that contains just one email: admin@example.com and nothing else sensitive."
        result = described_class.call(text: text)
        expect(result.fully_redacted?).to be false
      end
    end

    context "with Result" do
      it "tracks original length" do
        text = "Contact admin@example.com"
        result = described_class.call(text: text)
        expect(result.original_length).to eq(text.length)
      end

      it "tracks redaction metadata" do
        text = 'api_key = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"'
        result = described_class.call(text: text)
        redaction = result.redactions.first
        expect(redaction.pattern).to eq(:api_key)
        expect(redaction.offset).to be_a(Integer)
        expect(redaction.length).to be_a(Integer)
      end
    end
  end
end
