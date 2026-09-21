# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationWorkflowRevisions::SyncFromConfiguration do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:yaml) do
    <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: iOS/App.xcodeproj
            scheme: App
          tests:
            required: true
          captures:
            - id: initial-screen
              required: true
              flow:
                - launch_app: {}
                - capture:
                    name: initial-screen
    YAML
  end

  before { create(:apple_worker_profile, account:, constraints: { "platforms" => [ "ios" ], "xcode_version" => ">= 26.0" }) }

  it "creates a draft revision bound to the configuration's content digest and derived checks" do # @spec APPLE-WORKER-013
    revision = described_class.call(project:, content: yaml)

    expect(revision).to be_draft
    expect(revision.content_digest).to eq("sha256:#{Digest::SHA256.hexdigest(yaml)}")
    expect(revision.verification_files).to eq([ { "path" => ".paid/apple-verification.yml", "digest" => revision.content_digest } ])
    expect(revision.required_checks).to contain_exactly("ios-app.tests", "ios-app.initial-screen")
    expect(revision.lifecycle_gate).to eq("agent_iteration")
  end

  it "updates the existing draft in place rather than creating a second one" do # @spec APPLE-WORKER-013
    first = described_class.call(project:, content: yaml)

    changed_yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: iOS/App.xcodeproj
            scheme: App
          tests:
            required: false
    YAML
    second = described_class.call(project:, content: changed_yaml)

    expect(second.id).to eq(first.id)
    expect(project.apple_verification_workflow_revisions.count).to eq(1)
    expect(second.reload.advisory_checks).to include("ios-app.tests")
  end

  it "never mutates an approved revision's binding, instead creating a new draft" do # @spec APPLE-WORKER-013
    approved = create(:apple_verification_workflow_revision, :approved, project:, account:)

    changed_yaml = yaml.sub("App.xcodeproj", "Other.xcodeproj")
    draft = described_class.call(project:, content: changed_yaml)

    expect(draft.id).not_to eq(approved.id)
    expect(draft).to be_draft
    expect(approved.reload.content_digest).not_to eq(draft.content_digest)
  end

  it "raises a deterministic error when no active worker profile supports every declared platform" do # @spec APPLE-WORKER-013
    macos_yaml = yaml.sub("platform: ios", "platform: macos").sub("iOS/App.xcodeproj", "App.xcodeproj")

    expect { described_class.call(project:, content: macos_yaml) }
      .to raise_error(described_class::NoCompatibleWorkerProfileError, /macos/)
  end

  it "propagates a configuration parsing error without creating a revision" do # @spec APPLE-WORKER-013
    expect { described_class.call(project:, content: "version: 2\nprofiles: {}\n") }
      .to raise_error(AppleVerification::ConfigurationParser::ConfigurationError)
    expect(project.apple_verification_workflow_revisions.count).to eq(0)
  end
end
