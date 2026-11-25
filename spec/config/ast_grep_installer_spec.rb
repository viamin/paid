# frozen_string_literal: true

require "rails_helper"
require "open3"
require "socket"
require "timeout"

class AstGrepInstaller < Pathname
end

RSpec.describe AstGrepInstaller, :no_db do # @spec TEST-SUITE-024
  let(:directory) { Pathname(Dir.mktmpdir("ast-grep-contract")) }

  around do |example|
    directory.join("bin").mkpath
    directory.join("bin/curl").write(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
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
      end
    RUBY
    directory.join("bin/curl").chmod(0o755)
    example.run
  ensure
    FileUtils.remove_entry(directory)
  end

  it "terminates a stalled HTTP transfer through the real curl deadline and finite retries" do
    with_stalled_server do |url, requests|
      _output, error, status = run_installer("CURL_MODE" => "stalled", "TRANSFER_URL" => url,
        "AST_GREP_DOWNLOAD_CONNECT_TIMEOUT" => "0.1", "AST_GREP_DOWNLOAD_MAX_TIME" => "0.2")

      expect(status.exitstatus).to eq(28)
      expect(error).to match(/timed out/i)
      expect(requests.size).to eq(3)
      expect(curl_arguments).to include("--connect-timeout", "0.1", "--max-time", "0.2", "--retry", "2")
      expect(directory.join("installed/ast-grep")).not_to exist
    end
  end

  it "propagates a failed download without installing a binary" do
    _output, _error, status = run_installer("CURL_MODE" => "failed")

    expect(status.exitstatus).to eq(22)
    expect(directory.join("installed/ast-grep")).not_to exist
  end

  it "rejects a corrupt archive with the real pinned checksum verifier" do
    output, _error, status = run_installer("CURL_MODE" => "corrupt")

    expect(status).not_to be_success
    expect(output).to include("FAILED")
    expect(curl_arguments).to include("--connect-timeout", "15", "--max-time", "300")
    expect(directory.join("installed/ast-grep")).not_to exist
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

  def run_installer(settings)
    environment = settings.merge("PATH" => "#{directory}/bin:#{ENV.fetch("PATH")}",
      "INSTALL_DIR" => directory.join("installed").to_s,
      "CURL_ARGUMENTS" => directory.join("curl-arguments.json").to_s)
    Open3.popen3(environment, "bash", Rails.root.join("bin/install-ast-grep").to_s, pgroup: true) do |input, output, error, waiter|
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
