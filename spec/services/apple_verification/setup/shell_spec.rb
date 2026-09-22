# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::Setup::Shell do
  let(:capture) { ->(*argv) { fake_capture(*argv) } }
  let(:shell) { described_class.new(capture:) }

  def fake_capture(*argv)
    case argv
    when [ "which", "tart" ]
      [ "/opt/homebrew/bin/tart", "", instance_double(Process::Status, success?: true) ]
    when [ "false" ]
      [ "", "boom", instance_double(Process::Status, success?: false, to_i: 1) ]
    else
      [ "", "command not stubbed: #{argv.inspect}", instance_double(Process::Status, success?: false, to_i: 127) ]
    end
  end

  describe "#run" do
    it "wraps a captured process result with success? and stdout_lines helpers" do
      result = shell.run("which", "tart")

      expect(result).to be_success
      expect(result.stdout_lines).to eq([ "/opt/homebrew/bin/tart" ])
    end

    it "returns a CommandResult with a nil status when the binary is missing" do
      shell = described_class.new(capture: ->(*_argv) { raise Errno::ENOENT, "no such file" })
      result = shell.run("nope")

      expect(result.status).to be_nil
      expect(result.stderr).to include("ENOENT")
      expect(result).not_to be_success
    end
  end

  describe "#command_path" do
    it "returns the captured path on success" do
      expect(shell.command_path("tart")).to eq("/opt/homebrew/bin/tart")
    end

    it "returns nil when the binary is not on PATH" do
      shell = described_class.new(capture: ->(*_argv) { [ "", "not found", instance_double(Process::Status, success?: false) ] })
      expect(shell.command_path("nope")).to be_nil
    end
  end
end
