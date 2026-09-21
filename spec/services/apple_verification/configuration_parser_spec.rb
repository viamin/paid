# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::ConfigurationParser do
  let(:ios_yaml) do
    <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          worker:
            xcode: ">= 26.0, < 27.0"
            simulator: "iPhone 17"
          xcode:
            project: iOS/ColorMatchingLPS.xcodeproj
            scheme: ColorMatchingLPS
          tests:
            required: true
          captures:
            - id: initial-screen
              required: true
              flow:
                - launch_app: {}
                - wait_for_accessibility_id:
                    id: main-screen
                    timeout_seconds: 15
                - capture:
                    name: initial-screen
    YAML
  end

  let(:mac_yaml) do
    <<~YAML
      version: 1
      profiles:
        mac-app:
          platform: macos
          worker:
            xcode: "~> 26.0"
          xcode:
            workspace: Example.xcworkspace
            scheme: ExampleMac
            test_plan: Example.xctestplan
          bootstrap: spm
          tests:
            required: false
    YAML
  end

  it "parses Xcode project profiles with typed schemes, test plans, and captures" do # @spec APPLE-WORKER-011
    configuration = described_class.call(content: ios_yaml)

    profile = configuration.profiles.first
    expect(profile.name).to eq("ios-app")
    expect(profile.platform).to eq("ios")
    expect(profile.xcode.project).to eq("iOS/ColorMatchingLPS.xcodeproj")
    expect(profile.xcode.scheme).to eq("ColorMatchingLPS")
    expect(profile.tests_required).to be(true)
    expect(profile.captures.first.id).to eq("initial-screen")
    expect(profile.captures.first.flow.map(&:operation)).to eq(%w[launch_app wait_for_accessibility_id capture])
    expect(configuration.required_checks).to contain_exactly("ios-app.tests", "ios-app.initial-screen")
  end

  it "parses a native macOS workspace profile with Swift Package Manager and test plans" do # @spec APPLE-WORKER-011
    configuration = described_class.call(content: mac_yaml)
    profile = configuration.profiles.first

    expect(profile.platform).to eq("macos")
    expect(profile.xcode.workspace).to eq("Example.xcworkspace")
    expect(profile.xcode.test_plan).to eq("Example.xctestplan")
    expect(profile.bootstrap).to eq("spm")
    expect(configuration.advisory_checks).to contain_exactly("mac-app.tests")
    expect(configuration.required_checks).to be_empty
  end

  it "executes a mixed repository's multiple iOS and macOS profiles" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: iOS/App.xcodeproj
            scheme: App
        mac-app:
          platform: macos
          xcode:
            workspace: Mac.xcworkspace
            scheme: Mac
    YAML

    configuration = described_class.call(content: yaml)

    expect(configuration.profiles.map(&:name)).to contain_exactly("ios-app", "mac-app")
  end

  it "rejects an unknown declarative flow operation with a deterministic diagnostic" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: iOS/App.xcodeproj
            scheme: App
          captures:
            - id: initial-screen
              required: true
              flow:
                - run_shell: "rm -rf /"
    YAML

    expect { described_class.call(content: yaml) }
      .to raise_error(described_class::UnsupportedOperationError, /unknown operation run_shell/)
  end

  it "rejects an unsupported dependency bootstrap system with a deterministic diagnostic" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: iOS/App.xcodeproj
            scheme: App
          bootstrap: cocoapods
    YAML

    expect { described_class.call(content: yaml) }
      .to raise_error(described_class::UnsupportedBootstrapSystemError, /cocoapods/)
  end

  it "rejects an unsupported platform" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        watch-app:
          platform: watchos
          xcode:
            project: App.xcodeproj
            scheme: App
    YAML

    expect { described_class.call(content: yaml) }.to raise_error(described_class::ConfigurationError, /platform/)
  end

  it "rejects an xcode target declaring both project and workspace" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: App.xcodeproj
            workspace: App.xcworkspace
            scheme: App
    YAML

    expect { described_class.call(content: yaml) }.to raise_error(described_class::ConfigurationError, /exactly one/)
  end

  it "rejects an xcode target declaring neither project nor workspace" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            scheme: App
    YAML

    expect { described_class.call(content: yaml) }.to raise_error(described_class::ConfigurationError, /exactly one/)
  end

  it "rejects unknown top-level and profile fields" do # @spec APPLE-WORKER-011
    expect { described_class.call(content: "version: 1\nprofiles: {}\nextra: true\n") }
      .to raise_error(described_class::ConfigurationError, /unknown fields: extra/)

    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: App.xcodeproj
            scheme: App
          unknown_field: true
    YAML
    expect { described_class.call(content: yaml) }.to raise_error(described_class::ConfigurationError, /unknown fields: unknown_field/)
  end

  it "rejects an unsupported schema version" do # @spec APPLE-WORKER-011
    expect { described_class.call(content: "version: 2\nprofiles: {}\n") }
      .to raise_error(described_class::ConfigurationError, /version must be 1/)
  end

  it "rejects a missing or empty profiles mapping" do # @spec APPLE-WORKER-011
    expect { described_class.call(content: "version: 1\n") }.to raise_error(described_class::ConfigurationError, /profiles/)
    expect { described_class.call(content: "version: 1\nprofiles: {}\n") }.to raise_error(described_class::ConfigurationError, /profiles/)
  end

  it "rejects invalid YAML and non-mapping documents with a deterministic diagnostic" do # @spec APPLE-WORKER-011
    expect { described_class.call(content: "not: yaml: at: all: -") }.to raise_error(described_class::ConfigurationError, /invalid YAML/)
    expect { described_class.call(content: "- 1\n- 2\n") }.to raise_error(described_class::ConfigurationError, /YAML mapping/)
  end

  it "rejects YAML anchors, aliases, and merge keys with a deterministic diagnostic" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app: &ios_profile
          platform: ios
          xcode:
            project: App.xcodeproj
            scheme: App
        mac-app:
          <<: *ios_profile
          platform: macos
    YAML

    expect { described_class.call(content: yaml) }
      .to raise_error(described_class::ConfigurationError, /anchors or aliases/)
  end

  it "rejects a malformed worker.xcode constraint with a deterministic diagnostic" do # @spec APPLE-WORKER-011
    yaml = ios_yaml.sub('xcode: ">= 26.0, < 27.0"', "xcode: latest")

    expect { described_class.call(content: yaml) }
      .to raise_error(described_class::ConfigurationError, /worker\.xcode/)
  end

  it "rejects non-string worker constraints with a deterministic diagnostic" do # @spec APPLE-WORKER-011
    yaml = ios_yaml.sub('simulator: "iPhone 17"', "simulator: 17")

    expect { described_class.call(content: yaml) }
      .to raise_error(described_class::ConfigurationError, /worker\.simulator/)
  end

  it "builds a profile without screenshot requirements for build/test-only profiles" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        cli-tool:
          platform: macos
          xcode:
            project: Tool.xcodeproj
            scheme: Tool
          tests:
            required: true
    YAML

    configuration = described_class.call(content: yaml)

    expect(configuration.profiles.first.captures).to eq([])
    expect(configuration.required_checks).to eq([ "cli-tool.tests" ])
  end

  it "rejects duplicate capture ids within a profile" do # @spec APPLE-WORKER-011
    yaml = <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: App.xcodeproj
            scheme: App
          captures:
            - id: shot
              required: true
              flow:
                - launch_app: {}
            - id: shot
              required: false
              flow:
                - launch_app: {}
    YAML

    expect { described_class.call(content: yaml) }
      .to raise_error(described_class::ConfigurationError, /captures must have unique ids: shot/)
  end
end
