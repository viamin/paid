# frozen_string_literal: true

FactoryBot.define do
  factory :egress_security_event do
    account
    project { nil }
    agent_run { nil }
    event_kind { "denied_egress" }
    severity { "warn" }
    source_layer { "gateway" }
    destination_host { "blocked.example.com" }
    destination_port { 443 }
    scheme { "https" }
    matched_rule { "host not in allowlist" }
    redacted_evidence { "fp:abc123… truncated" }
    occurred_at { Time.current }

    trait :redacted_extraction do
      event_kind { "redacted_secret_extraction" }
      severity { "critical" }
      source_layer { "broker" }
      matched_rule { "request body contained high-entropy token" }
      redacted_evidence { "token fingerprint sha256:deadbeef… truncated" }
    end

    trait :allowlist_match do
      event_kind { "allowlist_match" }
      severity { "info" }
      matched_rule { "host matched account-level entry" }
    end

    trait :for_agent_run do
      agent_run
    end
  end
end
