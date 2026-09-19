# frozen_string_literal: true

FactoryBot.define do
  factory :apple_verification_image do
    account
    sequence(:name) { |n| "apple-worker-#{n}" }
    sequence(:digest) { |n| "sha256:#{format('%064d', n)}" }
    toolchain { { "macos_version" => "26.6.2", "macos_build" => "25G86", "xcode_version" => "26.6", "xcode_build" => "17F113", "sdk_versions" => [ "iOS 26.6", "macOS 26.6" ], "simulator_runtimes" => [ "iOS 26.6" ], "executor_version" => "1.0.0" } }
    resources { { "cpu_count" => 4, "memory_gib" => 8, "disk_gib" => 100 } }
    network_capability { { "mechanism" => "paid_proxy", "egress_enforced" => true } }
    gui_account { { "admin" => false, "apple_id" => false, "personal_data" => false, "host_credentials" => false, "persistent_secret_keychain" => false, "ready_gui_session" => true } }
    smoke_test { { "passed" => false, "completed_at" => Time.current.iso8601 } }
    provenance { { "build_id" => "operator-build-1" } }

    trait :active do
      smoke_test { { "passed" => true, "completed_at" => Time.current.iso8601 } }

      after(:create) do |image|
        image.promote!
      end
    end
  end
end
