# frozen_string_literal: true

FactoryBot.define do
  factory :supervisor_snapshot do
    account
    digest { { "schema_version" => 1, "metrics" => [ { "name" => "queue_starvation", "status" => "unavailable" } ] } }
    included_project_ids { [] }
    metric_provenance { { "window" => "PT24H", "denominator" => 0, "inclusion_rule" => "enabled_projects_only" } }
    captured_at { Time.current }
    retention_expires_at { 30.days.from_now }
  end
end
