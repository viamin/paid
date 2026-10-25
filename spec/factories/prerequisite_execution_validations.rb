# frozen_string_literal: true

FactoryBot.define do
  factory :prerequisite_execution_validation do
    project
    issue { association :issue, project: project }
    initiated_by { association :user }
    status { "pending" }
    branch { "main" }
    scope_digest { SecureRandom.hex(16) }
    contract do
      {
        "branch" => "main",
        "native_command" => "bin/lint",
        "tool" => nil,
        "steps" => [ { "key" => "native_analyzer", "command" => "bin/lint" } ]
      }
    end
    capability_snapshot { { "environment_available" => true, "compatible_hosts" => [], "missing" => [] } }
    steps { [] }
    evidence { {} }

    trait :with_agent_run do
      agent_run { association :agent_run, :synthetic, :manual, project: project, issue: nil, custom_prompt: "Collect prerequisite execution evidence", goal: "prerequisite_validation", status: "running", branch_name: "main" }
    end

    trait :running do
      status { "running" }
      started_at { 5.minutes.ago }
      with_agent_run
    end

    trait :succeeded do
      status { "succeeded" }
      started_at { 10.minutes.ago }
      finished_at { 5.minutes.ago }
      steps do
        [
          {
            "key" => "checkout_identity",
            "command" => "git clone + checkout main",
            "status" => "succeeded",
            "commit" => "0123456789abcdef0123456789abcdef01234567"
          },
          {
            "key" => "native_analyzer",
            "command" => "bin/lint",
            "status" => "succeeded",
            "exit_code" => 0,
            "stdout" => "clean",
            "stderr" => ""
          }
        ]
      end
      evidence do
        {
          "identity" => {
            "run" => { "container_id" => "abc123", "container_host" => "local", "image" => "paid-agent:latest" },
            "checkout" => { "branch" => "main", "commit" => "0123456789abcdef0123456789abcdef01234567" }
          },
          "cleanup" => { "run_container" => "cleaned", "sidecars" => "not_provisioned" }
        }
      end
    end

    trait :unavailable do
      status { "unavailable" }
      finished_at { Time.current }
      capability_snapshot do
        {
          "environment_available" => false,
          "compatible_hosts" => [],
          "missing" => [
            { "kind" => "host_capability", "message" => "No enabled Docker host is configured for this account, so Paid cannot provision an isolated run.",
              "authorized_action" => "Add or enable a Docker host (Settings → Docker hosts) so Paid can provision isolated runs on a placement-ready backend." }
          ]
        }
      end
    end
  end
end
