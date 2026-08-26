# frozen_string_literal: true

FactoryBot.define do
  factory :page_load_measurement do
    project
    account { project.account }
    pull_request_number { 42 }
    commit_sha { "abc1234def5678" }
    route_name { "dashboard" }
    route_path { "/dashboard" }
    http_status { 200 }
    source { "screenshot_capture" }
    ttfb_ms { 90 }
    dcl_ms { 420 }
    load_ms { 810 }
    fcp_ms { 380 }
    lcp_ms { 640 }
    sample_count { 3 }
    samples { { "load_ms" => { "values" => [ 780, 810, 903 ], "min" => 780, "max" => 903 } } }
    viewport_width { 1280 }
    viewport_height { 900 }
    captured_at { Time.current }
  end
end
