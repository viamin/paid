# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::Research::SecretGuard do # @spec EGRESS-POLICY-009
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  describe ".inspect!" do
    it "blocks exact run proxy token matches" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "https://docs.example.com/?token=#{agent_run.proxy_token}",
        destination_host: "docs.example.com"
      )

      expect(result.blocked?).to be(true)
      expect(result.rule).to include("known")
      expect(result.redacted_evidence).not_to include(agent_run.proxy_token)
    end

    it "blocks known redaction-pattern matches" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn",
        destination_host: "docs.example.com"
      )

      expect(result.blocked?).to be(true)
      expect(result.rule).to include("secret")
    end

    it "blocks high-entropy tokens that do not match a named scanner rule" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "AAAAB3NzaC1yc2EAAAADAQABAAABAQDbx8Y5w2g8Rr6KqNnLzP4sT7vH9mQ2kL3pW0zX1cV6",
        destination_host: "docs.example.com"
      )

      expect(result.blocked?).to be(true)
      expect(result.rule).to include("entropy")
    end

    it "permits ordinary documentation queries" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "https://docs.example.com/platform/guide",
        destination_host: "docs.example.com"
      )

      expect(result.blocked?).to be(false)
    end

    it "permits plain-English token documentation queries" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "token authentication guide",
        destination_host: "duckduckgo.com"
      )

      expect(result.blocked?).to be(false)
    end

    it "permits long documentation URLs whose path letter frequencies resemble random keys" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "https://en.wikipedia.org/wiki/Row-level_security",
        destination_host: "en.wikipedia.org"
      )

      expect(result.blocked?).to be(false)
    end

    it "permits long API documentation URLs without query parameters" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "https://api.stripe.com/docs/api/cards/object",
        destination_host: "api.stripe.com"
      )

      expect(result.blocked?).to be(false)
    end

    it "permits long forum URLs whose path has dashes and slashes but no query" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "https://stackoverflow.com/questions/11828270/how-do-i-exit-the-vim-editor",
        destination_host: "stackoverflow.com"
      )

      expect(result.blocked?).to be(false)
    end

    it "still blocks high-entropy tokens that appear only in a query parameter value" do
      result = described_class.inspect!(
        agent_run: agent_run,
        text: "https://docs.example.com/guide?token=AAAAB3NzaC1yc2EAAAADAQABAAABAQDbx8Y5w2g8Rr6KqNnLzP4sT7vH9mQ2kL3pW0zX1cV6",
        destination_host: "docs.example.com"
      )

      expect(result.blocked?).to be(true)
      expect(result.rule).to include("entropy")
    end
  end

  describe ".redact_text" do
    it "preserves long URL paths instead of redacting them as high-entropy tokens" do
      redacted = described_class.redact_text(
        "https://en.wikipedia.org/wiki/Row-level_security"
      )

      expect(redacted).to include("Row-level_security")
      expect(redacted).not_to include("[REDACTED:high_entropy]")
    end

    it "redacts high-entropy tokens that appear inside query parameter values" do
      redacted = described_class.redact_text(
        "https://docs.example.com/guide?token=AAAAB3NzaC1yc2EAAAADAQABAAABAQDbx8Y5w2g8Rr6KqNnLzP4sT7vH9mQ2kL3pW0zX1cV6"
      )

      expect(redacted).to include("[REDACTED:high_entropy]")
      expect(redacted).not_to include("AAAAB3NzaC1yc2EAAAADAQABAAABAQDbx8Y5w2g8Rr6KqNnLzP4sT7vH9mQ2kL3pW0zX1cV6")
    end
  end
end
