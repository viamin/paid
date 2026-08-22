# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

class GenerateAgentImageMetadata
end

RSpec.describe GenerateAgentImageMetadata, :no_db do # @spec IMMUTABLE-IMAGE-007
  def run_script(env_overrides = {})
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "agent-image-metadata.json")
      env = base_env(output_path).merge(env_overrides)

      stdout, stderr, status = Open3.capture3(
        env,
        "bundle",
        "exec",
        "ruby",
        "scripts/generate-agent-image-metadata.rb",
        chdir: Rails.root.to_s
      )

      payload = File.exist?(output_path) ? JSON.parse(File.read(output_path)) : nil
      return [ stdout, stderr, status, payload ]
    end
  end

  def base_env(output_path)
    {
      "OUTPUT_PATH" => output_path,
      "PROFILE_NAME" => "base",
      "IMAGE_TAG" => "latest",
      "REQUESTED_IMAGE" => "paid-agent:latest",
      "REGISTRY" => "ghcr.io",
      "REPOSITORY" => "viamin/paid-agent",
      "DIGEST" => "sha256:#{'a' * 64}",
      "ARCHITECTURE" => "x86_64",
      "BUILT_AT" => "2026-08-22T12:34:56Z",
      "GIT_SHA" => "0123456789abcdef0123456789abcdef01234567",
      "CI_PROVENANCE_URL" => "https://github.com/viamin/paid/actions/runs/123456789",
      "BUNDLER_VERSION" => "4.0.14",
      "RUBY_MAAT_VERSION" => "1.2.0",
      "AGENT_HARNESS_VERSION" => "0.34.1",
      "AGENT_HARNESS_GIT_REF" => "deadbeefcafebabe",
      "GITHUB_WORKFLOW" => "Agent Image",
      "GITHUB_REPOSITORY" => "viamin/paid",
      "GITHUB_RUN_ID" => "123456789",
      "GITHUB_RUN_ATTEMPT" => "2",
      "VERIFIED_CHECKS" => "smoke_test,runner_contract_smoke_test"
    }
  end

  def expect_registry_record(payload)
    expect(payload.fetch("schema_version")).to eq(1)
    expect(payload.fetch("registry_record")).to include(
      "name" => "base",
      "tag" => "latest",
      "registry" => "ghcr.io",
      "repository" => "viamin/paid-agent",
      "digest" => "sha256:#{'a' * 64}",
      "architecture" => "amd64",
      "status" => "active"
    )
    expect(payload.fetch("registry_record").fetch("metadata")).to include(
      "requested_image" => "paid-agent:latest",
      "resolved_image" => "ghcr.io/viamin/paid-agent@sha256:#{'a' * 64}"
    )
    expect(payload.fetch("registry_record").dig("provenance", "lockfile")).to eq(
      "bundler_version" => "4.0.14",
      "ruby_maat_version" => "1.2.0",
      "agent_harness_version" => "0.34.1",
      "agent_harness_git_ref" => "deadbeefcafebabe"
    )
  end

  def expect_activation_patch(payload)
    reference = "base-amd64-2026-08-22-0123456789ab"

    expect(payload.fetch("activation")).to include(
      "requested_image" => "paid-agent:latest",
      "default_reference" => reference,
      "candidate_reference" => reference,
      "status" => "active",
      "tested" => true
    )
    expect(payload.fetch("runtime_catalog_patch")).to eq(
      "profiles" => {
        "paid-agent:latest" => {
          "operations" => {
            "set_default_reference" => reference,
            "upsert_identities" => {
              reference => {
                "digest" => "sha256:#{'a' * 64}",
                "architecture" => "amd64",
                "registry" => "ghcr.io",
                "repository" => "viamin/paid-agent",
                "status" => "active"
              }
            }
          }
        }
      }
    )
  end

  it "emits an agent image registry record plus activation metadata" do
    _stdout, stderr, status, payload = run_script

    expect(status.success?).to be(true), -> { stderr }
    expect_registry_record(payload)
  end

  it "emits a runtime catalog patch that activates the smoke-tested digest by reference" do
    _stdout, stderr, status, payload = run_script

    expect(status.success?).to be(true), -> { stderr }
    expect_activation_patch(payload)
  end

  it "requires at least one verified check before marking a digest active" do
    _stdout, stderr, status, payload = run_script("VERIFIED_CHECKS" => "")

    expect(status.success?).to be(false)
    expect(payload).to be_nil
    expect(stderr).to include("VERIFIED_CHECKS is required")
  end
end
