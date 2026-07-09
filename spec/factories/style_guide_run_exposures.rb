# frozen_string_literal: true

FactoryBot.define do
  factory :style_guide_run_exposure do
    agent_run
    style_guide
    style_guide_version { style_guide.current_version || style_guide.style_guide_versions.order(version: :desc).first }
    guide_name { style_guide.name }
    source_scope { "account" }
    sequence(:position) { |n| n - 1 }
    injected_via { "Spec" }
    injected_content { style_guide_version.content_for_prompt(project: agent_run.project) }
  end
end
