# frozen_string_literal: true

require "rails_helper"
require "open3"
require "socket"
require "timeout"
require "zlib"
require "digest"

class AstGrepInstaller < Pathname
end

RSpec.describe AstGrepInstaller, :no_db do # @spec TEST-SUITE-024, TEST-SUITE-031
  let(:directory) { Pathname(Dir.mktmpdir("ast-grep-contract")) }
  let(:cache_dir) { directory.join("ast-grep-cache") }
  let(:install_dir) { directory.join("installed") }
  let(:pinned_version) do
    Rails.root.join("bin/install-ast-grep").read[/AST_GREP_VERSION="\$\{AST_GREP_VERSION:-(\d+\.\d+\.\d+)\}"/, 1]
  end
  let(:rust_triple) do
    case Open3.capture2("dpkg", "--print-architecture").first.strip
    when "amd64" then "x86_64-unknown-linux-gnu"
    when "arm64" then "aarch64-unknown-linux-gnu"
    else raise "unsupported test architecture for ast-grep cache contract"
    end
  end
  let(:other_rust_triple) do
    rust_triple == "aarch64-unknown-linux-gnu" ? "x86_64-unknown-linux-gnu" : "aarch64-unknown-linux-gnu"
  end

  around do |example|
    directory.join("bin").mkpath
    directory.join("bin/curl").write(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      require "fileutils"
      File.write(ENV.fetch("CURL_ARGUMENTS"), JSON.generate(ARGV))
      case ENV.fetch("CURL_MODE")
      when "stalled"
        arguments = ARGV.dup
        arguments[-1] = ENV.fetch("TRANSFER_URL")
        exec("/usr/bin/curl", *arguments)
      when "failed"
        exit 22
      when "corrupt"
        File.binwrite(ARGV.fetch(ARGV.index("-o") + 1), "corrupt release archive")
      when "serve"
        FileUtils.cp(ENV.fetch("RELEASE_ARCHIVE"), ARGV.fetch(ARGV.index("-o") + 1))
      end
    RUBY
    directory.join("bin/curl").chmod(0o755)
    example.run
  ensure
    FileUtils.remove_entry(directory)
  end

  it "terminates a stalled HTTP transfer through the real curl deadline and finite retries" do
    with_stalled_server do |url, requests|
      _output, error, status = run_installer({ "CURL_MODE" => "stalled", "TRANSFER_URL" => url,
        "AST_GREP_DOWNLOAD_CONNECT_TIMEOUT" => "0.1", "AST_GREP_DOWNLOAD_MAX_TIME" => "0.2" })

      expect(status.exitstatus).to eq(28)
      expect(error).to match(/timed out/i)
      expect(requests.size).to eq(3)
      expect(curl_arguments).to include("--connect-timeout", "0.1", "--max-time", "0.2", "--retry", "2")
      expect(directory.join("installed/ast-grep")).not_to exist
    end
  end

  it "propagates a failed download without installing a binary" do
    _output, _error, status = run_installer({ "CURL_MODE" => "failed" })

    expect(status.exitstatus).to eq(22)
    expect(directory.join("installed/ast-grep")).not_to exist
  end

  it "rejects a corrupt archive with the real pinned checksum verifier" do
    output, _error, status = run_installer({ "CURL_MODE" => "corrupt" })

    expect(status).not_to be_success
    expect(output).to include("FAILED")
    expect(curl_arguments).to include("--connect-timeout", "15", "--max-time", "300")
    expect(install_dir.join("ast-grep")).not_to exist
  end

  # @spec TEST-SUITE-031
  it "restores a valid cache entry without transferring the release archive" do
    entry = write_cache_entry(version: pinned_version)
    install_dir.mkpath

    output, _error, status = run_installer({ "CURL_MODE" => "failed" })

    expect(status).to be_success
    expect(output).to include("Restored ast-grep #{pinned_version}")
    expect(output).to include(entry.to_s)
    expect(directory.join("curl-arguments.json")).not_to exist
    expect(install_dir.join("ast-grep")).to be_executable
    expect(Open3.capture3(install_dir.join("ast-grep").to_s, "--version").first).to include(pinned_version)
    expect(install_dir.join("sg")).to be_symlink
    expect(install_dir.join("sg").readlink).to eq(install_dir.join("ast-grep"))
  end

  # @spec TEST-SUITE-031
  it "rejects a wrong-version cache entry and falls back to the bounded release download" do
    write_cache_entry(version: "0.44.0")

    _output, _error, status = run_installer({ "CURL_MODE" => "failed" })

    expect(status.exitstatus).to eq(22)
    expect(directory.join("curl-arguments.json")).to exist
    expect(install_dir.join("ast-grep")).not_to exist
    expect(pinned_cache_entry).not_to exist
  end

  # @spec TEST-SUITE-031
  it "rejects a non-executable cache entry and falls back to the bounded release download" do
    write_cache_entry(version: pinned_version, executable: false)

    _output, _error, status = run_installer({ "CURL_MODE" => "failed" })

    expect(status.exitstatus).to eq(22)
    expect(directory.join("curl-arguments.json")).to exist
    expect(install_dir.join("ast-grep")).not_to exist
  end

  # @spec TEST-SUITE-031
  it "ignores cache entries stored for another architecture" do
    write_cache_entry(version: pinned_version, triple: other_rust_triple)

    _output, _error, status = run_installer({ "CURL_MODE" => "failed" })

    expect(status.exitstatus).to eq(22)
    expect(directory.join("curl-arguments.json")).to exist
    expect(install_dir.join("ast-grep")).not_to exist
    expect(pinned_cache_entry).not_to exist
  end

  # @spec TEST-SUITE-031
  it "stores no cache entry when the bounded release download fails" do
    _output, _error, status = run_installer({ "CURL_MODE" => "failed" })

    expect(status.exitstatus).to eq(22)
    expect(pinned_cache_entry).not_to exist
    expect(cache_dir.children).to be_empty if cache_dir.exist?
  end

  # @spec TEST-SUITE-031
  describe "a checksum-verified release download" do
    let(:release_archive) { directory.join("release.zip") }
    let(:patched_installer) do
      write_release_archive(release_archive, pinned_version)
      path = directory.join("install-ast-grep")
      path.write(checksum_patched_installer(release_archive))
      path
    end
    let(:verified_download) do
      install_dir.mkpath
      run_installer(
        { "CURL_MODE" => "serve", "RELEASE_ARCHIVE" => release_archive.to_s },
        installer: patched_installer
      )
    end

    it "stores the installed binary as a cache entry" do
      output, _error, status = verified_download

      expect(status).to be_success
      expect(output).to include("Cached ast-grep #{pinned_version}")
      expect(install_dir.join("ast-grep")).to be_executable
      expect(install_dir.join("sg")).to be_symlink
      expect(pinned_cache_entry).to be_executable
    end

    it "restores the cache entry on the next run without another transfer" do
      verified_download
      second_install_dir = directory.join("installed-again")
      second_install_dir.mkpath

      output, _error, status = run_installer(
        { "CURL_MODE" => "failed", "CURL_ARGUMENTS" => directory.join("curl-arguments-again.json").to_s },
        installer: patched_installer, install_dir: second_install_dir
      )
      expect(status).to be_success
      expect(output).to include("Restored ast-grep #{pinned_version}")
      expect(directory.join("curl-arguments-again.json")).not_to exist
      expect(second_install_dir.join("ast-grep")).to be_executable
      expect(second_install_dir.join("sg").readlink).to eq(second_install_dir.join("ast-grep"))
    end
  end

  def pinned_cache_entry
    cache_dir.join("ast-grep-#{pinned_version}-#{rust_triple}")
  end

  def write_cache_entry(version:, triple: rust_triple, executable: true)
    cache_dir.mkpath
    entry = cache_dir.join("ast-grep-#{version}-#{triple}")
    entry.write("#!/bin/sh\necho \"ast-grep #{version}\"\n")
    entry.chmod(executable ? 0o755 : 0o644)
    entry
  end

  # Writes the single-file release archive the installer expects: a zip whose
  # only member is the executable "ast-grep" binary. Stored (uncompressed)
  # entries keep the writer in the standard library.
  def write_release_archive(path, version)
    contents = "#!/bin/sh\necho \"ast-grep #{version}\"\n"
    crc = Zlib.crc32(contents)
    name = "ast-grep".b
    local = [ 0x04034b50, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
              name.bytesize, 0 ].pack("VvvvvvVVVvv") + name + contents
    central = [ 0x02014b50, 20, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
                name.bytesize, 0, 0, 0, 0, (0o100644 << 16), 0 ].pack("VvvvvvvVVVvvvvvVV") + name
    record = [ 0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0 ].pack("VvvvvVVv")
    File.binwrite(path, local + central + record)
  end

  # The pinned upstream archive cannot be reproduced offline, so the successful
  # download path runs against a copy of the real installer whose checksum for
  # the pinned version is replaced with the fixture archive's digest. Only the
  # checksum value differs; the download, verify, install, and cache steps are
  # the production script's.
  def checksum_patched_installer(archive)
    checksum = Digest::SHA256.file(archive).hexdigest
    Rails.root.join("bin/install-ast-grep").read
      .gsub(/^(\s+#{Regexp.escape(pinned_version)}\) EXPECTED_CHECKSUM=")[0-9a-f]+(")/) do
        "#{Regexp.last_match(1)}#{checksum}#{Regexp.last_match(2)}"
      end
  end

  def with_stalled_server
    server = TCPServer.new("127.0.0.1", 0)
    sockets = []
    requests = Queue.new
    responder = Thread.new do
      3.times do
        socket = server.accept
        sockets << socket
        requests << true
        while (line = socket.gets)
          break if line == "\r\n"
        end
        socket.read
        socket.close
      end
    rescue IOError, Errno::EBADF
      # Closing this fixture's listener interrupts an unfinished accept.
    end

    yield "http://127.0.0.1:#{server.addr[1]}/archive.zip", requests
  ensure
    sockets&.each { |socket| socket.close unless socket.closed? }
    server&.close
    responder&.join
  end

  def curl_arguments
    JSON.parse(directory.join("curl-arguments.json").read)
  end

  def run_installer(settings, installer: nil, install_dir: nil)
    installer ||= Rails.root.join("bin/install-ast-grep")
    install_dir ||= directory.join("installed")
    environment = settings.merge("PATH" => "#{directory}/bin:#{ENV.fetch("PATH")}",
      "INSTALL_DIR" => install_dir.to_s,
      "AST_GREP_CACHE_DIR" => cache_dir.to_s,
      "CURL_ARGUMENTS" => directory.join("curl-arguments.json").to_s)
    Open3.popen3(environment, "bash", installer.to_s, pgroup: true) do |input, output, error, waiter|
      input.close
      output_reader = Thread.new { output.read }
      error_reader = Thread.new { error.read }
      begin
        status = Timeout.timeout(12) { waiter.value }
        [ output_reader.value, error_reader.value, status ]
      ensure
        unless waiter.join(0)
          Process.kill("TERM", -waiter.pid)
          waiter.join
        end
        output_reader.join
        error_reader.join
      end
    end
  end
end
