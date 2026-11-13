# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::DockerExecWithStdin, :no_db do
  # @spec LLM-ROUTING-006
  it "requests an upgraded, attached exec and returns its completed exit status" do
    connection = instance_double(Docker::Connection)
    container = instance_double(Docker::Container, id: "container-1", connection: connection)
    execution = instance_double(Docker::Exec, id: "exec-1", json: { "ExitCode" => 7 })
    allow(Docker::Exec).to receive(:create).and_return(execution)
    allow(connection).to receive(:post)

    result = described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5)

    expect(Docker::Exec).to have_received(:create).with(hash_including(
      "Container" => "container-1", "Cmd" => [ "cat" ], "AttachStdin" => true
    ), connection)
    expect(connection).to have_received(:post).with("/exec/exec-1/start", nil, hash_including(
      headers: { "Connection" => "Upgrade", "Upgrade" => "tcp" }, expects: [ 101 ],
      read_timeout: 5, hijack_block: kind_of(Proc)
    ))
    expect(result).to eq([ [], [], 7 ])
  end

  # @spec LLM-ROUTING-006
  it "returns the command status when Docker closes stdin before consuming it" do
    connection = instance_double(Docker::Connection)
    container = instance_double(Docker::Container, id: "container-1", connection: connection)
    execution = instance_double(Docker::Exec, id: "exec-1", json: { "ExitCode" => 7 })
    socket = instance_double(IO)
    allow(Docker::Exec).to receive(:create).and_return(execution)
    allow(socket).to receive(:write).and_raise(Errno::EPIPE)
    allow(socket).to receive(:readpartial).and_raise(EOFError)
    allow(connection).to receive(:post) do |_path, _query, options|
      options.fetch(:hijack_block).call(socket)
    end

    result = described_class.call(container:, command: [ "false" ], stdin: StringIO.new("input"), wait: 5)

    expect(result).to eq([ [], [], 7 ])
  end

  describe "Docker integration", :runner_smoke do
    around do |example|
      WebMock.disable!
      example.run
    ensure
      WebMock.enable!
      WebMock.disable_net_connect!(allow_localhost: true)
    end

    # @spec LLM-ROUTING-006
    it "delivers a large input and waits for the exit status in a read-only container" do
      container = Docker::Container.create(
        "Image" => Containers::ImageResolver::BASE_IMAGE,
        "Cmd" => [ "sleep", "60" ],
        "ReadonlyRootfs" => true,
        "OpenStdin" => false
      )
      container.start
      input = StringIO.new("x" * 300_000)

      stdout, stderr, status = described_class.call(container:, command: [ "python3", "-c",
        "import sys; print(len(sys.stdin.buffer.read(300000)))" ], stdin: input, wait: 10)

      expect(stdout.join).to eq("300000\n")
      expect(stderr).to be_empty
      expect(status).to eq(0)
    ensure
      container&.delete(force: true)
    end

    # @spec LLM-ROUTING-006
    it "waits for a quiet command to finish after it consumes stdin" do
      container = Docker::Container.create(
        "Image" => Containers::ImageResolver::BASE_IMAGE,
        "Cmd" => [ "sleep", "60" ],
        "ReadonlyRootfs" => true,
        "OpenStdin" => false
      )
      container.start

      stdout, stderr, status = described_class.call(container:,
        command: [ "python3", "-c",
          "import sys, time; sys.stdin.buffer.read(3); time.sleep(2); print('done')" ],
        stdin: StringIO.new("abc"), wait: 10)

      expect(stdout.join).to eq("done\n")
      expect(stderr).to be_empty
      expect(status).to eq(0)
    ensure
      container&.delete(force: true)
    end

    # @spec LLM-ROUTING-006
    it "returns promptly when the command exits before reading a large input" do
      container = Docker::Container.create(
        "Image" => Containers::ImageResolver::BASE_IMAGE,
        "Cmd" => [ "sleep", "60" ],
        "ReadonlyRootfs" => true,
        "OpenStdin" => false
      )
      container.start

      stdout, stderr, status = described_class.call(container:,
        command: [ "sh", "-c", "exit 7" ], stdin: StringIO.new("x" * 300_000), wait: 10)

      expect(stdout).to be_empty
      expect(stderr).to be_empty
      expect(status).to eq(7)
    ensure
      container&.delete(force: true)
    end
  end
end
