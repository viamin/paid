# frozen_string_literal: true

FactoryBot.define do
  factory :supervisor_incident do
    account
    sequence(:fingerprint) { |n| Digest::SHA256.hexdigest("supervisor-incident-#{n}") }
    category { "queue_starvation" }
    severity { "urgent" }
    status { "open" }
    affected_project_ids { [] }
    target_ids { { "project_ids" => [] } }
    evidence { { "metric_names" => [ "queue_starvation" ] } }
    model_identifier { "model-v1" }
    prompt_identifier { "prompt-v1" }
    policy_identifier { "policy-v1" }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    occurrence_count { 1 }
    retention_expires_at { 365.days.from_now }
  end
end

FactoryBot.define do
  factory :supervisor_incident_audit do
    supervisor_incident
    account { supervisor_incident.account }
    action { "opened" }
    evidence { { "snapshot_id" => 1 } }
    occurred_at { Time.current }
  end
end
