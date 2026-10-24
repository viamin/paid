# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# @spec PROJECT-READINESS-001, PROJECT-READINESS-002, PROJECT-READINESS-003, PROJECT-READINESS-004, PROJECT-READINESS-011, PROJECT-READINESS-013, POLYGLOT-TEST-003
RSpec.describe Projects::Readiness do
  def evaluate(tdd_mode:, language:, repo_profile: {}, fixture: nil, files: [], directories: [], executable_files: [])
    project = build(:project, tdd_mode:, primary_language: language, repo_profile:)

    if fixture
      described_class.call(project:, repo_path: fixture)
    else
      Dir.mktmpdir do |repo_path|
        directories.each { |directory| FileUtils.mkdir_p(File.join(repo_path, directory)) }
        files.each do |file, contents|
          path = File.join(repo_path, file)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, contents || "fixture\n")
        end
        executable_files.each { |file| FileUtils.chmod("u+x", File.join(repo_path, file)) }
        return described_class.call(project:, repo_path:)
      end
    end
  end

  def forager_ios_fixture
    Rails.root.join("spec/fixtures/projects/forager-ios")
  end

  def godot_install_on_demand_fixture
    Rails.root.join("spec/fixtures/projects/godot-gdunit4-ready")
  end

  def godot_command_configuration(files: [], directories: [], executable_files: [])
    project = build(:project, primary_language: "GDScript")

    Dir.mktmpdir do |repo_path|
      directories.each { |directory| FileUtils.mkdir_p(File.join(repo_path, directory)) }
      files.each do |file, contents|
        path = File.join(repo_path, file)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents || "fixture\n")
      end
      executable_files.each { |file| FileUtils.chmod("u+x", File.join(repo_path, file)) }
      yield Projects::Readiness::Detectors::Godot.new(project:, repo_path:)
    end
  end

  def verification_config(services: [])
    <<~YAML
      routes:
        - path: /
          name: Home
      services: #{services.to_json}
    YAML
  end

  def verification_config_with_unparseable_base_url
    <<~YAML
      base_url: "http://local host:3000"
      routes:
        - path: /
          name: Home
    YAML
  end

  describe ".call" do
    it "reports every strict-TDD prerequisite absent from the current Forager-iOS fixture" do
      result = evaluate(tdd_mode: "strict", language: "GDScript", fixture: forager_ios_fixture)

      expect(result.gaps.map(&:kind)).to contain_exactly(
        "missing_ci",
        "missing_test_directory",
        "missing_test_command"
      )
      expect(result.gaps.find { |gap| gap.kind == "missing_test_directory" }.evidence).to include(
        ecosystem: "godot", checked_paths: %w[test tests]
      )
      expect(result.evaluated_at).to be_a(ActiveSupport::TimeWithZone)
      expect(result.to_h).to include(evaluated_at: result.evaluated_at.iso8601)
    end

    it "returns no gaps when a strict Ruby project has CI and a test directory" do
      result = evaluate(
        tdd_mode: "strict",
        language: "Ruby",
        directories: [ ".github/workflows", "spec" ],
        files: [ ".github/workflows/test.yml" ]
      )

      expect(result).to be_satisfied
      expect(result.gaps).to be_empty
    end

    it "applies the same structural TDD prerequisites in non-strict mode" do
      result = evaluate(tdd_mode: "non_strict", language: "Python")

      expect(result.gaps.map(&:kind)).to contain_exactly("missing_ci", "missing_test_directory")
      expect(result.gaps.find { |gap| gap.kind == "missing_test_directory" }.evidence).to include(
        ecosystem: "python", checked_paths: %w[tests test]
      )
    end

    it "recognizes a non-strict Python project with all prerequisites" do
      result = evaluate(
        tdd_mode: "non_strict",
        language: "Python",
        directories: [ ".github/workflows", "tests" ],
        files: [ ".github/workflows/test.yml" ]
      )

      expect(result).to be_satisfied
    end

    it "uses configured test languages when checking test directories" do
      result = evaluate(
        tdd_mode: "strict",
        language: "Ruby",
        repo_profile: { "test_languages" => [ "python" ] },
        directories: [ ".github/workflows", "tests" ],
        files: [ ".github/workflows/test.yml" ]
      )

      expect(result).to be_satisfied
    end

    it "adds no TDD gaps when TDD mode is off" do
      result = evaluate(tdd_mode: "off", language: "GDScript", fixture: forager_ios_fixture)

      expect(result).to be_satisfied
    end

    it "recognizes an installed gdUnit4 command" do # @spec PROJECT-READINESS-013
      result = evaluate(
        tdd_mode: "strict", language: "GDScript",
        directories: [ ".github/workflows", "tests" ],
        files: [ ".github/workflows/gdunit4.yml", "addons/gdUnit4/bin/GdUnitCmdTool.gd" ]
      )

      expect(result).to be_satisfied
    end

    it "recognizes an ignored addon with the supported install-on-demand contract" do # @spec PROJECT-READINESS-013
      result = evaluate(
        tdd_mode: "strict", language: "GDScript",
        directories: [ ".github/workflows", "tests", "addons/gdUnit4" ],
        files: [ ".github/workflows/gdunit4.yml", "bin/install-test-tools", "bin/test" ],
        executable_files: [ "bin/install-test-tools", "bin/test" ]
      )

      expect(result).to be_satisfied
    end

    it "recognizes the isolated gdUnit4 install-on-demand fixture without running it" do # @spec PROJECT-READINESS-013
      result = evaluate(tdd_mode: "strict", language: "GDScript", fixture: godot_install_on_demand_fixture)

      expect(result).to be_satisfied
    end

    it "requires both supported executable entry points when gdUnit4 is not installed" do # @spec PROJECT-READINESS-013
      result = evaluate(
        tdd_mode: "strict", language: "GDScript",
        directories: [ ".github/workflows", "tests" ],
        files: [ ".github/workflows/gdunit4.yml", "bin/test" ],
        executable_files: [ "bin/test" ]
      )

      expect(result.gaps.map(&:kind)).to contain_exactly("missing_test_command")
    end

    it "does not run a failed installer while evaluating install-on-demand configuration" do # @spec PROJECT-READINESS-013
      result = evaluate(
        tdd_mode: "strict", language: "GDScript",
        directories: [ ".github/workflows", "tests" ],
        files: {
          ".github/workflows/gdunit4.yml" => "name: gdUnit4\n",
          "bin/install-test-tools" => "#!/bin/sh\nexit 1\n",
          "bin/test" => "#!/bin/sh\nexit 1\n"
        },
        executable_files: [ "bin/install-test-tools", "bin/test" ]
      )

      expect(result).to be_satisfied
    end

    it "distinguishes installed, setup-required, and unavailable gdUnit4 commands" do # @spec PROJECT-READINESS-013
      godot_command_configuration(files: [ "addons/gdUnit4/bin/GdUnitCmdTool.gd" ]) do |detector|
        expect(detector.test_command_configuration.status).to eq(:installed)
      end

      godot_command_configuration(
        files: [ "bin/install-test-tools", "bin/test" ],
        executable_files: [ "bin/install-test-tools", "bin/test" ]
      ) do |detector|
        expect(detector.test_command_configuration.status).to eq(:setup_required)
      end

      godot_command_configuration(directories: [ "addons/gdUnit4" ]) do |detector|
        expect(detector.test_command_configuration.status).to eq(:unavailable)
      end
    end

    it "reports parseable verification setup prerequisites from the checkout" do
      project = build(:project, tdd_mode: "off", screenshot_settings: { "verification_enabled" => true })

      Dir.mktmpdir do |repo_path|
        FileUtils.mkdir_p(File.join(repo_path, ".paid"))
        File.write(File.join(repo_path, ".paid/screenshots.yml"), verification_config(services: [ "postgres" ]))

        result = described_class.call(project:, repo_path:)

        expect(result.gaps.map(&:kind)).to contain_exactly(
          "app_start_command_unavailable",
          "missing_verification_service"
        )
      end
    end

    it "reports invalid verification configuration as a repository setup gap" do
      project = build(:project, tdd_mode: "off", screenshot_settings: { "verification_enabled" => true })

      Dir.mktmpdir do |repo_path|
        FileUtils.mkdir_p(File.join(repo_path, ".paid"))
        File.write(File.join(repo_path, ".paid/screenshots.yml"), "routes: invalid\n")

        result = described_class.call(project:, repo_path:)

        expect(result.gaps.map(&:kind)).to eq([ "verification_configuration_invalid" ])
      end
    end

    it "reports an unparseable base_url as a repository setup gap instead of raising" do
      project = build(:project, tdd_mode: "off", screenshot_settings: { "verification_enabled" => true })

      Dir.mktmpdir do |repo_path|
        FileUtils.mkdir_p(File.join(repo_path, ".paid"))
        File.write(File.join(repo_path, ".paid/screenshots.yml"), verification_config_with_unparseable_base_url)

        result = described_class.call(project:, repo_path:)

        expect(result.gaps.map(&:kind)).to eq([ "verification_configuration_invalid" ])
      end
    end

    it "does not evaluate verification prerequisites when verification is disabled" do
      result = evaluate(tdd_mode: "off", language: "Ruby")

      expect(result).to be_satisfied
    end
  end
end
