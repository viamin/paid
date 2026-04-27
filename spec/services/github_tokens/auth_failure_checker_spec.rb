# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubTokens::AuthFailureChecker do
  describe "#auth_failure?" do
    it "detects git clone authentication failures" do
      [
        "fatal: Authentication failed for 'https://github.com/org/repo.git'",
        "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
        "The requested URL returned error: 403 Forbidden",
        "The requested URL returned error: 401 Unauthorized",
        "HTTP 403: access denied",
        "HTTP 401: unauthorized"
      ].each do |msg|
        checker = described_class.new(error_message: msg)
        expect(checker.auth_failure?).to be(true), "Expected auth failure for: #{msg}"
      end
    end

    it "detects proxy 503 responses" do
      [
        "GitCredentials proxy returned 503",
        "GithubProxy responded with 503",
        "proxy error 503"
      ].each do |msg|
        checker = described_class.new(error_message: msg)
        expect(checker.auth_failure?).to be(true), "Expected auth failure for: #{msg}"
      end
    end

    it "detects GithubClient authentication errors" do
      [
        "GithubClient::AuthenticationError: Invalid or expired GitHub token",
        "Token is invalid or has been revoked: Bad credentials",
        "Bad credentials",
        "Unauthorized"
      ].each do |msg|
        checker = described_class.new(error_message: msg)
        expect(checker.auth_failure?).to be(true), "Expected auth failure for: #{msg}"
      end
    end

    it "returns false for non-auth errors" do
      [
        "Container crashed with exit code 1",
        "Timeout after 300 seconds",
        "No changes detected",
        "Rate limit exceeded",
        ""
      ].each do |msg|
        checker = described_class.new(error_message: msg)
        expect(checker.auth_failure?).to be(false), "Expected no auth failure for: #{msg.inspect}"
      end
    end

    it "returns false for nil error message" do
      checker = described_class.new(error_message: nil)
      expect(checker.auth_failure?).to be(false)
    end
  end

  describe "#call" do
    it "returns the matched pattern for auth errors" do
      checker = described_class.new(error_message: "Authentication failed for repo")
      expect(checker.call).to be_a(Regexp)
    end

    it "returns nil for non-auth errors" do
      checker = described_class.new(error_message: "Container crashed")
      expect(checker.call).to be_nil
    end
  end
end
