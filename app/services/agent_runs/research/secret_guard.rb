# frozen_string_literal: true

require "digest"

module AgentRuns
  module Research
    class SecretGuard
      Result = Data.define(:blocked, :rule, :redacted_evidence) do
        def blocked?
          blocked
        end
      end

      HIGH_ENTROPY_CANDIDATE = /[A-Za-z0-9+\/=_-]{24,}/
      KNOWN_TOKEN_PATTERNS = [
        /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
        /\bAKIA[0-9A-Z]{16}\b/,
        /\bASIA[0-9A-Z]{16}\b/,
        /\b(?:Bearer|token|session|cookie)[=: ]+[A-Za-z0-9._~+\/=-]{12,}/i
      ].freeze

      def self.inspect!(...)
        new.inspect!(...)
      end

      def self.redact_text(text)
        normalized = text.to_s
        clean = Knowledge::Redaction::Redactor.call(text: normalized).clean_text
        clean.gsub(HIGH_ENTROPY_CANDIDATE) do |candidate|
          high_entropy?(candidate) ? "[REDACTED:high_entropy]" : candidate
        end
      end

      def inspect!(agent_run:, text:, destination_host:)
        normalized = text.to_s

        known_secret = exact_known_secret(agent_run, normalized)
        return blocked_result("matched known issued/proxied secret", known_secret) if known_secret

        scanner_match = Knowledge::Redaction::Scanner.scan(normalized).first
        return blocked_result("matched existing secret-scanning rule", scanner_match.pattern) if scanner_match

        token_shape = KNOWN_TOKEN_PATTERNS.find { |pattern| normalized.match?(pattern) }
        return blocked_result("matched known token shape", token_shape.source) if token_shape

        candidate = normalized.scan(HIGH_ENTROPY_CANDIDATE).find { |value| self.class.high_entropy?(value) }
        return blocked_result("matched high entropy token", candidate) if candidate

        Result.new(blocked: false, rule: nil, redacted_evidence: nil)
      end

      def self.high_entropy?(value)
        text = value.to_s
        return false if text.length < 24

        counts = text.chars.tally
        entropy = counts.values.sum do |count|
          p = count.to_f / text.length
          -p * Math.log2(p)
        end
        entropy >= 3.5
      end

      private

      def exact_known_secret(agent_run, text)
        known_secrets(agent_run).find { |secret| secret.present? && text.include?(secret) }
      end

      def known_secrets(agent_run)
        proxy_token = agent_run.ensure_proxy_token!
        account_secrets = agent_run.project.account.integration_credentials.active.map(&:secret)

        [
          proxy_token,
          "paid-run:#{agent_run.id}:#{proxy_token}",
          "Bearer paid-run:#{agent_run.id}:#{proxy_token}",
          *account_secrets
        ].compact.uniq
      end

      def blocked_result(rule, evidence)
        Result.new(
          blocked: true,
          rule: rule,
          redacted_evidence: "sha256:#{Digest::SHA256.hexdigest(evidence.to_s)[0, 16]}"
        )
      end
    end
  end
end
