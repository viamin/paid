# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ci::TransientFailure do
  let(:github_client) { instance_double(GithubClient) }
  let(:repo) { "owner/repo" }

  before do
    allow(github_client).to receive(:check_run_log).and_return("")
  end

  describe ".call" do
    it "returns false for empty checks" do
      result = described_class.call(checks: [], github_client: github_client, repo: repo)
      expect(result).to be false
    end

    it "detects network errors as transient" do
      checks = [
        { id: 1, name: "test", conclusion: "failure",
          output_text: "Error: getaddrinfo ENOTFOUND registry.npmjs.org" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "detects connection timeouts as transient" do
      checks = [
        { id: 1, name: "test", conclusion: "failure",
          output_text: "connect ETIMEDOUT 104.16.23.35:443" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "detects HTTP 502/503/504 as transient" do
      checks = [
        { id: 1, name: "test", conclusion: "failure",
          output_text: "HTTP 503 Service Unavailable" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "detects rate limiting as transient" do
      checks = [
        { id: 1, name: "test", conclusion: "failure",
          output_text: "API rate limit exceeded for installation" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "detects registry fetch errors as transient" do
      checks = [
        { id: 1, name: "install", conclusion: "failure",
          output_text: "npm ERR! network request to https://registry.npmjs.org failed" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "detects gem fetch errors as transient" do
      checks = [
        { id: 1, name: "bundle", conclusion: "failure",
          output_text: "Could not fetch specs from https://rubygems.org/" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "treats timed_out conclusion as transient when no code failures present" do
      checks = [
        { id: 1, name: "test", conclusion: "timed_out", output_text: "" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "treats cancelled conclusion as transient when no code failures present" do
      checks = [
        { id: 1, name: "test", conclusion: "cancelled", output_text: "" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be true
    end

    it "returns false for code failures like SyntaxError" do
      checks = [
        { id: 1, name: "test", conclusion: "failure",
          output_text: "SyntaxError: unexpected token" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end

    it "returns false for test failures" do
      checks = [
        { id: 1, name: "rspec", conclusion: "failure",
          output_text: "12 examples, 3 failures\ntest failed: expected true got false" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end

    it "returns false for lint failures" do
      checks = [
        { id: 1, name: "rubocop", conclusion: "failure",
          output_text: "3 files inspected, 2 offenses detected\nrubocop offense found" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end

    it "returns false for compilation errors" do
      checks = [
        { id: 1, name: "build", conclusion: "failure",
          output_text: "error TS2304: Cannot find name 'foo'" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end

    it "returns false when any check has code failures even if others are transient" do
      checks = [
        { id: 1, name: "install", conclusion: "failure",
          output_text: "connect ETIMEDOUT 104.16.23.35:443" },
        { id: 2, name: "test", conclusion: "failure",
          output_text: "SyntaxError: unexpected end of input" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end

    it "checks job logs when output_text is empty" do
      check = { id: 1, name: "test", conclusion: "failure", output_text: "" }
      allow(github_client).to receive(:check_run_log)
        .with(repo, check)
        .and_return("Error: getaddrinfo ENOTFOUND api.github.com")

      expect(described_class.call(checks: [ check ], github_client: github_client, repo: repo)).to be true
    end

    it "returns false for plain failure conclusion with no transient signals" do
      checks = [
        { id: 1, name: "test", conclusion: "failure", output_text: "" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end

    it "handles GithubClient errors when fetching logs" do
      check = { id: 1, name: "test", conclusion: "timed_out", output_text: "" }
      allow(github_client).to receive(:check_run_log)
        .and_raise(GithubClient::Error.new("API error"))

      expect(described_class.call(checks: [ check ], github_client: github_client, repo: repo)).to be true
    end

    it "prioritizes code failure patterns over transient patterns" do
      checks = [
        { id: 1, name: "test", conclusion: "failure",
          output_text: "Net::ReadTimeout connecting to test server\nSyntaxError: unexpected token }" }
      ]

      expect(described_class.call(checks: checks, github_client: github_client, repo: repo)).to be false
    end
  end
end
