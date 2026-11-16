# frozen_string_literal: true

FactoryBot.define do
  factory :supervisor_snapshot do
    account
    digest { { "schema_version" => 1, "metrics" => [ { "name" => "queue_starvation", "status" => "unavailable", "value" => nil } ] } }
    included_project_ids { [] }
    metric_provenance do
      [ { "name" => "queue_starvation", "window" => "PT24H", "denominator" => 0, "inclusion_rule" => "enabled_projects_only" } ]
    end
    captured_at { Time.current }
    retention_expires_at { 30.days.from_now }
  end
end
