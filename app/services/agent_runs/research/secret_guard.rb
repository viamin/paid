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

      # NOTE: the candidate charset deliberately excludes `/`. Path segments
      # (e.g. `org/wiki/Row-level_security`) are ordinary English text whose
      # letter frequencies are indistinguishable from random keys at this
      # scale; including `/` would let a candidate span path segments and
      # trigger false positives on legitimate documentation URLs.
      HIGH_ENTROPY_CANDIDATE = /[A-Za-z0-9+=_-]{24,}/
      KNOWN_TOKEN_PATTERNS = [
        /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
        /\bAKIA[0-9A-Z]{16}\b/,
        /\bASIA[0-9A-Z]{16}\b/,
        /\b(?:Bearer|token|session|cookie)[=: ]+(?=[A-Za-z0-9._~+\/=-]*\d)[A-Za-z0-9._~+\/=-]{12,}/i
      ].freeze

      def self.inspect!(...)
        new.inspect!(...)
      end

      # Records the blocked-secret finding for a brokered-research caller:
      # emits the security event, audits the blocked request, and returns
      # nothing. Callers raise RequestInvalidError afterward so the 422
      # path is consistent. Centralizing the bookkeeping keeps the three
      # callers (Fetcher + Search outbound/redirect) from drifting in
      # security-critical logging.
      def self.block_and_record!(agent_run:, result:, destination_host:, audit_event:, actor_id:, metadata:)
        EgressSecurityEvent.create!(
          account: agent_run.project.account,
          project: agent_run.project,
          agent_run: agent_run,
          event_kind: "redacted_secret_extraction",
          severity: "critical",
          source_layer: "broker",
          destination_host: destination_host,
          matched_rule: result.rule,
          redacted_evidence: result.redacted_evidence,
          occurred_at: Time.current
        )
        ExecutionAuditEvents::Lifecycle.record(
          event_name: audit_event,
          actor_id: actor_id,
          agent_run: agent_run,
          networking_policy: agent_run.egress_policy_snapshot || {},
          metadata: metadata.merge(
            "policy_result" => "blocked_secret",
            "matched_rule" => result.rule
          )
        )
      end

      def self.redact_text(text)
        normalized = text.to_s
        clean = Knowledge::Redaction::Redactor.call(text: normalized).clean_text
        candidates = redaction_targets(clean)
          .flat_map { |target| target.scan(HIGH_ENTROPY_CANDIDATE) }
          .select { |candidate| high_entropy?(candidate) }
          .uniq
          .sort_by { |candidate| -candidate.length }

        candidates.each do |candidate|
          clean = clean.gsub(candidate, "[REDACTED:high_entropy]")
        end
        clean
      end

      def inspect!(agent_run:, text:, destination_host:)
        normalized = text.to_s

        known_secret = exact_known_secret(agent_run, normalized)
        return blocked_result("matched known issued/proxied secret", known_secret) if known_secret

        scanner_match = Knowledge::Redaction::Scanner.scan(normalized).first
        return blocked_result("matched existing secret-scanning rule", scanner_match.pattern) if scanner_match

        # Token-shape and high-entropy scans only target values where
        # credentials actually live: query-string parameter values on URLs
        # (userinfo and fragments are rejected upstream by the broker), or the
        # raw text in the non-URL search-query flow. Path segments are not
        # scanned because their letter frequencies are indistinguishable from
        # random keys at this scale.
        targets = self.class.redaction_targets(normalized)

        token_shape = KNOWN_TOKEN_PATTERNS.find { |pattern| targets.any? { |t| t.match?(pattern) } }
        return blocked_result("matched known token shape", token_shape.source) if token_shape

        candidate = targets.flat_map { |t| t.scan(HIGH_ENTROPY_CANDIDATE) }
          .find { |value| self.class.high_entropy?(value) }
        return blocked_result("matched high entropy token", candidate) if candidate

        Result.new(blocked: false, rule: nil, redacted_evidence: nil)
      end

      # Returns the substrings that should be scanned for high-entropy
      # credentials. For URLs, that's the query-string parameter values
      # (userinfo and fragments are rejected upstream by the broker); for
      # non-URL text, the whole input.
      def self.redaction_targets(text)
        url = parse_url(text)
        return [ text ] if url.nil? || url.query.blank?

        URI.decode_www_form(url.query).filter_map { |_name, value| value.presence }
      end

      def self.parse_url(text)
        uri = URI.parse(text)
        return nil unless uri.scheme.present? && uri.host.present?

        uri
      rescue URI::InvalidURIError
        nil
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
