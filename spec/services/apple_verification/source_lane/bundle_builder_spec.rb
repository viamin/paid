# frozen_string_literal: true

require "rails_helper"
require "rubygems/package"
require "tmpdir"
require "zlib"

# @spec APPLE-TRANSFER-002
# @spec APPLE-TRANSFER-003
RSpec.describe AppleVerification::SourceLane::BundleBuilder do
  let(:workspace_root) { Dir.mktmpdir("apple-bundle-") }
  let(:output_path) { File.join(workspace_root, "source.tar.gz") }

  after do
    FileUtils.remove_entry(workspace_root) if File.directory?(workspace_root)
  end

  def write_file(relative_path, contents)
    absolute = File.join(workspace_root, relative_path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
    absolute
  end

  it "produces a digest, manifest, and tar archive that omits forbidden paths" do
    write_file("Sources/App.swift", "let greeting = \"hello\"\n")
    write_file(".env", "GH_TOKEN=ghp_supersecrettoken1234567890123456789012345\n")
    write_file("secrets/id_rsa", "-----BEGIN OPENSSH PRIVATE KEY-----\n")
    write_file("Pods/Pods.xcodeproj/file.pbxproj", "// generated\n")
    write_file("DerivedData/Index/DataStore/index.pb", "binary")
    write_file("node_modules/express/index.js", "module.exports = {};")
    write_file(".build/debug/App", "binary")

    result = described_class.call(workspace_root: workspace_root, output_path: output_path)

    expect(result.digest).to match(/\Asha256:[a-f0-9]{64}\z/)
    expect(result.bytesize).to be > 0
    expect(File.exist?(output_path)).to be(true)
    expect(File.exist?(result.manifest_path)).to be(true)

    manifest = JSON.parse(File.binread(result.manifest_path))
    included_paths = manifest["files"].map { |entry| entry["path"] }
    expect(included_paths).to include("Sources/App.swift")
    expect(included_paths).not_to include(".env", "secrets/id_rsa", "Pods/Pods.xcodeproj/file.pbxproj",
      "DerivedData/Index/DataStore/index.pb", "node_modules/express/index.js", ".build/debug/App")
    excluded_paths = manifest["excluded_paths"].map { |entry| entry["path"] }
    expect(excluded_paths).to include(".env", "secrets/id_rsa", "Pods/Pods.xcodeproj/file.pbxproj")
  end

  it "raises SecretFoundError when an included file matches a secret pattern" do
    write_file("Sources/App.swift", "let greeting = \"hello\"\n")
    write_file("Sources/Helpers/App.swift", "let ghp = \"ghp_supersecrettoken1234567890123456789012345\"\n")

    expect {
      described_class.call(workspace_root: workspace_root, output_path: output_path)
    }.to raise_error(described_class::SecretFoundError, /secret-shaped file/)
  end

  it "raises SecretFoundError when a secret is embedded past the first 8 KiB of a file" do
    padding = "let padding = \"hello world\"; let n = 0\n" * 400
    secret = "let ghp = \"ghp_supersecrettoken1234567890123456789012345\"\n"
    write_file("Sources/Big.swift", padding + secret)

    expect {
      described_class.call(workspace_root: workspace_root, output_path: output_path)
    }.to raise_error(described_class::SecretFoundError, /secret-shaped file/)
  end

  it "raises BundleTooLargeError when the bundle exceeds the configured cap" do
    write_file("Sources/App.swift", "a" * 1024)
    write_file("Sources/Helpers/Big.swift", "b" * 1024)

    expect {
      described_class.call(workspace_root: workspace_root, output_path: output_path, max_bytes: 1024)
    }.to raise_error(described_class::BundleTooLargeError, /exceeds/)
  end

  it "preserves each included file's permission bits in the tar entries" do
    script = write_file("Scripts/build.sh", "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, script)
    write_file("Sources/App.swift", "let greeting = \"hello\"\n")

    result = described_class.call(workspace_root: workspace_root, output_path: output_path)
    modes = tar_entry_modes(result.bundle_path)

    expect(modes["Scripts/build.sh"]).to eq(0o755)
    expect(modes["Sources/App.swift"]).to eq(0o644)
  end

  def tar_entry_modes(bundle_path)
    Zlib::GzipReader.open(bundle_path) do |gz|
      Gem::Package::TarReader.new(gz).each_with_object({}) do |entry, modes|
        modes[entry.full_name] = entry.header.mode
      end
    end
  end

  it "rejects symlinks that escape the workspace root" do
    outside = File.join(Dir.mktmpdir("apple-outside-"), "secret.txt")
    File.binwrite(outside, "outside")
    link_path = File.join(workspace_root, "link_to_outside")
    File.symlink(outside, link_path)
    write_file("Sources/App.swift", "let greeting = \"hello\"\n")

    expect {
      described_class.call(workspace_root: workspace_root, output_path: output_path)
    }.not_to raise_error

    FileUtils.remove_entry(File.dirname(outside))
  end

  it "raises WorkspaceInvalidError when the workspace root does not exist" do
    expect {
      described_class.call(workspace_root: "/tmp/does-not-exist-#{SecureRandom.hex(4)}", output_path: "/tmp/foo.tar")
    }.to raise_error(described_class::WorkspaceInvalidError, /does not exist/)
  end
end
