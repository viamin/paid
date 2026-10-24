# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-READINESS-008 PROJECT-READINESS-012
RSpec.describe Projects::Readiness::BootstrapWriteGuard do
  describe ".call" do
    it "allows Godot CI, harness, and test layout artifacts" do
      result = described_class.call(changed_files: [
        ".github/workflows/gdunit.yml", "project.godot", "addons/gdUnit4/plugin.cfg", "tests/.gitkeep"
      ])

      expect(result).to be_valid
      expect(result.forbidden_files).to eq([])
    end

    it "allows each conventional test directory layout" do
      result = described_class.call(changed_files: [
        "spec/example_spec.rb", "test/example_test.rb", "tests/example_test.py",
        "__tests__/example.test.js", "Tests/ExampleTests.swift"
      ])

      expect(result).to be_valid
      expect(result.forbidden_files).to eq([])
    end

    it "allows the verification configuration needed by a bootstrap repair" do
      result = described_class.call(changed_files: [ ".paid/screenshots.yml" ])

      expect(result).to be_valid
    end

    it "allows a minimal Godot bin/test repair selected by a missing-command gap" do
      result = described_class.call(
        changed_files: [ "bin/test" ],
        readiness_gaps: [ { "kind" => "missing_test_command", "evidence" => { "ecosystem" => "godot" } } ]
      )

      expect(result).to be_valid
    end

    it "allows the explicitly selected Godot installer" do
      result = described_class.call(
        changed_files: [ "bin/install-test-tools" ],
        readiness_gaps: [ { "kind" => "missing_test_command", "evidence" => { "ecosystem" => "godot" } } ]
      )

      expect(result).to be_valid
    end

    it "rejects entry points when readiness has not selected the Godot setup contract" do
      result = described_class.call(changed_files: [ "bin/test" ])

      expect(result).not_to be_valid
      expect(result.forbidden_files).to eq([ "bin/test" ])
    end

    it "rejects unrelated bin paths, application code, and non-canonical paths" do
      result = described_class.call(
        changed_files: [ "bin/deploy", "scripts/player.gd", "bin/../app/player.gd", "/bin/test" ],
        readiness_gaps: [ { "kind" => "missing_test_command", "evidence" => { "ecosystem" => "godot" } } ]
      )

      expect(result).not_to be_valid
      expect(result.forbidden_files).to eq([ "bin/deploy", "scripts/player.gd", "bin/../app/player.gd", "/bin/test" ])
    end

    it "rejects a mixed authorized and forbidden diff with every offending path" do
      result = described_class.call(
        changed_files: [ "bin/test", "app/player.gd", "bin/deploy" ],
        readiness_gaps: [ { "kind" => "missing_test_command", "evidence" => { "ecosystem" => "godot" } } ]
      )

      expect(result).not_to be_valid
      expect(result.forbidden_files).to eq([ "app/player.gd", "bin/deploy" ])
    end

    it "rejects behavior-bearing files outside the harness class" do
      result = described_class.call(changed_files: [ ".github/workflows/gdunit.yml", "scripts/player.gd" ])

      expect(result).not_to be_valid
      expect(result.forbidden_files).to eq([ "scripts/player.gd" ])
      expect(result.reason).to include("entry scripts selected by current readiness evidence")
    end
  end
end
