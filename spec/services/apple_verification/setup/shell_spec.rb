# frozen_string_literal: true

require "rails_helper"
require "tmpdir"
require "fileutils"

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

  describe "#tart_home_dir" do
    around do |example|
      original_home = ENV["HOME"]
      original_tart_home = ENV["TART_HOME"]
      example.run
    ensure
      ENV["HOME"] = original_home
      ENV["TART_HOME"] = original_tart_home
    end

    it "prefers TART_HOME over the default ~/.tart" do
      ENV["HOME"] = "/tmp/example-home"
      ENV["TART_HOME"] = "/tmp/custom-tart"

      expect(shell.tart_home_dir).to eq("/tmp/custom-tart")
    end

    it "falls back to $HOME/.tart when TART_HOME is unset or blank" do
      ENV["HOME"] = "/tmp/example-home"
      ENV["TART_HOME"] = nil

      expect(shell.tart_home_dir).to eq("/tmp/example-home/.tart")
    end

    it "ignores a blank TART_HOME override" do
      ENV["HOME"] = "/tmp/example-home"
      ENV["TART_HOME"] = "   "

      expect(shell.tart_home_dir).to eq("/tmp/example-home/.tart")
    end
  end

  describe "#local_tart_vm_names" do
    around do |example|
      original_tart_home = ENV["TART_HOME"]
      example.run
    ensure
      ENV["TART_HOME"] = original_tart_home
    end

    it "returns the sorted directory names under <tart_home>/vms" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir
        FileUtils.mkdir_p(File.join(dir, "vms", "paid-vm-2"))
        FileUtils.mkdir_p(File.join(dir, "vms", "paid-vm-1"))
        FileUtils.mkdir_p(File.join(dir, "vms", ".hidden"))
        File.write(File.join(dir, "vms", "stray.txt"), "")

        expect(shell.local_tart_vm_names).to eq([ "paid-vm-1", "paid-vm-2" ])
      end
    end

    it "returns an empty array when the vms directory is missing" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir

        expect(shell.local_tart_vm_names).to eq([])
      end
    end

    it "refuses to traverse paths that escape the vms root" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir
        FileUtils.mkdir_p(File.join(dir, "vms", "../escape"))

        expect(shell.local_tart_vm_names).not_to include("..")
      end
    end
  end

  describe "#vm_dir_digest" do
    around do |example|
      original_tart_home = ENV["TART_HOME"]
      example.run
    ensure
      ENV["TART_HOME"] = original_tart_home
    end

    it "produces a deterministic digest that covers every non-hidden file" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir
        vm_dir = File.join(dir, "vms", "paid-macos-base")
        FileUtils.mkdir_p(vm_dir)
        File.write(File.join(vm_dir, "config.json"), "{\"name\":\"paid-macos-base\"}")
        File.write(File.join(vm_dir, "nvram.bin"), "nvram-bytes")
        FileUtils.mkdir_p(File.join(vm_dir, "subdir"))
        File.write(File.join(vm_dir, "subdir", "manifest.json"), "{}")
        File.write(File.join(vm_dir, ".explicitly-pulled"), "")

        first_digest = shell.vm_dir_digest("paid-macos-base")
        expect(first_digest).to match(/\A[a-f0-9]{64}\z/)

        # Re-running produces the same digest.
        expect(shell.vm_dir_digest("paid-macos-base")).to eq(first_digest)
      end
    end

    it "returns nil for a VM the directory walker refuses" do
      expect(shell.vm_dir_digest("../escape")).to be_nil
    end

    it "returns nil when the VM directory is missing" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir

        expect(shell.vm_dir_digest("missing")).to be_nil
      end
    end

    it "produces a different digest when file content changes" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir
        vm_dir = File.join(dir, "vms", "paid-macos-base")
        FileUtils.mkdir_p(vm_dir)
        File.write(File.join(vm_dir, "disk.img"), "contents-A")

        before = shell.vm_dir_digest("paid-macos-base")
        File.write(File.join(vm_dir, "disk.img"), "contents-B")

        expect(shell.vm_dir_digest("paid-macos-base")).not_to eq(before)
      end
    end

    it "ignores files inside hidden directories at any depth" do
      Dir.mktmpdir do |dir|
        ENV["TART_HOME"] = dir
        vm_dir = File.join(dir, "vms", "paid-macos-base")
        FileUtils.mkdir_p(File.join(vm_dir, ".cache", "subdir"))
        File.write(File.join(vm_dir, "config.json"), "{}")
        File.write(File.join(vm_dir, ".cache", "subdir", "ignored.txt"), "ignored")

        baseline = shell.vm_dir_digest("paid-macos-base")

        File.write(File.join(vm_dir, ".cache", "subdir", "ignored.txt"), "mutated")
        File.write(File.join(vm_dir, ".explicitly-pulled"), "")

        expect(shell.vm_dir_digest("paid-macos-base")).to eq(baseline)
      end
    end
  end
end
