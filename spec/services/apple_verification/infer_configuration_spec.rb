# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::InferConfiguration do
  it "derives a profile from a shared scheme in a committed Xcode project" do # @spec APPLE-WORKER-012
    paths = %w[
      iOS/App.xcodeproj/project.pbxproj
      iOS/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme
      iOS/AppTests/AppTests.swift
    ]

    result = described_class.call(paths:)

    expect(result["version"]).to eq(1)
    profile = result["profiles"].fetch("app")
    expect(profile["xcode"]["project"]).to eq("iOS/App.xcodeproj")
    expect(profile["xcode"]["scheme"]).to eq("App")
    expect(profile["tests"]["required"]).to be(true)
    expect(profile["captures"].first["id"]).to eq("initial-screen")
  end

  it "derives a profile from a shared scheme in a committed Xcode workspace with a test plan" do # @spec APPLE-WORKER-012
    paths = %w[
      Example.xcworkspace/contents.xcworkspacedata
      Example.xcworkspace/xcshareddata/xcschemes/Example.xcscheme
      Example.xctestplan
    ]

    result = described_class.call(paths:)
    profile = result["profiles"].fetch("example")

    expect(profile["xcode"]["workspace"]).to eq("Example.xcworkspace")
    expect(profile["xcode"]["test_plan"]).to eq("Example.xctestplan")
  end

  it "marks Swift Package Manager dependency resolution when a manifest is present" do # @spec APPLE-WORKER-012
    paths = %w[
      Package.swift
      App.xcodeproj/xcshareddata/xcschemes/App.xcscheme
    ]

    result = described_class.call(paths:)

    expect(result["profiles"].fetch("app")["bootstrap"]).to eq("spm")
  end

  it "returns no profiles for a repository with no detected Xcode project" do # @spec APPLE-WORKER-012
    result = described_class.call(paths: %w[README.md app/main.go])

    expect(result["profiles"]).to eq({})
  end

  it "raises a deterministic diagnostic for an unsupported bootstrap system with no committed workspace" do # @spec APPLE-WORKER-012
    expect { described_class.call(paths: %w[Podfile Podfile.lock]) }
      .to raise_error(AppleVerification::ConfigurationParser::ConfigurationError, /cocoapods/)
  end

  it "ignores unsupported bootstrap markers when a workspace is already committed" do # @spec APPLE-WORKER-012
    paths = %w[
      Podfile
      App.xcworkspace/xcshareddata/xcschemes/App.xcscheme
    ]

    result = described_class.call(paths:)

    expect(result["profiles"]).to have_key("app")
  end
end
