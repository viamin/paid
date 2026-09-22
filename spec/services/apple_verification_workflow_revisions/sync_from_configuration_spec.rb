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

  it "binds a profile whose advertised Xcode range falls within the declared worker constraint" do # @spec APPLE-WORKER-013
    constrained_yaml = yaml.sub("platform: ios", "platform: ios\n    worker:\n      xcode: \">= 26.0\"")

    revision = described_class.call(project:, content: constrained_yaml)

    expect(revision.apple_worker_profile.constraints["xcode_version"]).to eq(">= 26.0")
  end

  it "binds a profile whose pessimistic Xcode range falls within the declared worker constraint" do # @spec APPLE-WORKER-013
    create(:apple_worker_profile, account:, name: "ios-pinned",
      constraints: { "platforms" => [ "ios" ], "xcode_version" => "~> 26.0" })
    constrained_yaml = yaml.sub("platform: ios", "platform: ios\n    worker:\n      xcode: \">= 26.0, < 27.0\"")

    revision = described_class.call(project:, content: constrained_yaml)

    expect(revision.apple_worker_profile.name).to eq("ios-pinned")
  end

  it "raises when the profile's advertised Xcode range escapes the declared worker constraint" do # @spec APPLE-WORKER-013
    constrained_yaml = yaml.sub("platform: ios", "platform: ios\n    worker:\n      xcode: \">= 26.0, < 27.0\"")

    expect { described_class.call(project:, content: constrained_yaml) }
      .to raise_error(described_class::NoCompatibleWorkerProfileError, /worker\.xcode: >= 26\.0, < 27\.0/)
  end

  it "binds a profile advertising every declared simulator constraint" do # @spec APPLE-WORKER-013
    create(:apple_worker_profile, account:, name: "ios-simulator",
      constraints: { "platforms" => [ "ios" ], "xcode_version" => ">= 26.0", "simulator_runtimes" => [ "iOS 26.6" ] })
    simulator_yaml = yaml.sub("platform: ios", "platform: ios\n    worker:\n      simulator: iOS 26.6")

    revision = described_class.call(project:, content: simulator_yaml)

    expect(revision.apple_worker_profile.name).to eq("ios-simulator")
  end

  it "raises when no active worker profile advertises the declared simulator constraint" do # @spec APPLE-WORKER-013
    simulator_yaml = yaml.sub("platform: ios", "platform: ios\n    worker:\n      simulator: iOS 26.6")

    expect { described_class.call(project:, content: simulator_yaml) }
      .to raise_error(described_class::NoCompatibleWorkerProfileError, /worker\.simulator: iOS 26\.6/)
  end

  it "propagates a configuration parsing error without creating a revision" do # @spec APPLE-WORKER-013
    expect { described_class.call(project:, content: "version: 2\nprofiles: {}\n") }
      .to raise_error(AppleVerification::ConfigurationParser::ConfigurationError)
    expect(project.apple_verification_workflow_revisions.count).to eq(0)
  end
end
