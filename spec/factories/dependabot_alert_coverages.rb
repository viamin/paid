# frozen_string_literal: true

FactoryBot.define do
  factory :dependabot_alert_coverage do
    association :project
    account { project.account }
    alert_number { 1 }
    dependency_name { "brace-expansion" }
    dependency_ecosystem { "npm" }
    manifest_path { "package-lock.json" }
    advisory_ghsa_id { "GHSA-0000-0000-0000" }
    alert_state { "open" }
    coverage_state { "unknown" }
    reason { "unknown" }
    first_detected_at { Time.current }
    last_detected_at { Time.current }
  end
end
