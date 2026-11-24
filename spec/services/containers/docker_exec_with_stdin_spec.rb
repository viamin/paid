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

  # @spec LLM-ROUTING-013
  it "recomputes the transport timeout before starting the upgraded stream" do
    connection = instance_double(Docker::Connection, url: "tcp://docker:2376", options: { timeout: 60 })
    start_connection = instance_double(Docker::Connection)
    container = instance_double(Docker::Container, id: "container-1", connection: connection)
    execution = instance_double(Docker::Exec, id: "exec-1", json: { "ExitCode" => 0 })
    active_connection = connection
    allow(container).to receive(:connection) { active_connection }
    allow(container).to receive(:connection=) { |selected| active_connection = selected }
    allow(described_class::DeadlineConnection).to receive(:new).and_return(start_connection)
    allow(Docker::Exec).to receive(:create).and_return(execution)
    allow(start_connection).to receive(:post).with(any_args)
    allow(described_class).to receive(:monotonic_now).and_return(100.0, 100.0, 103.0)

    described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5, deadline: 5)

    expect(Docker::Exec).to have_received(:create).with(anything, start_connection)
    expect(start_connection).to have_received(:post).with("/exec/exec-1/start", nil,
      hash_including(read_timeout: 2.0))
  end

  # @spec LLM-ROUTING-013
  it "does not start an upgraded stream after exec creation exhausts its deadline" do
    connection = instance_double(Docker::Connection, url: "tcp://docker:2376", options: { timeout: 60 })
    create_connection = instance_double(Docker::Connection)
    container = instance_double(Docker::Container, id: "container-1", connection: connection)
    execution = instance_double(Docker::Exec, id: "exec-1", json: { "ExitCode" => 0 })
    allow(container).to receive(:connection=)
    allow(Docker::Connection).to receive(:new).and_return(create_connection)
    allow(Docker::Exec).to receive(:create).and_return(execution)
    allow(described_class).to receive(:monotonic_now).and_return(100.0, 100.0, 105.0)

    expect {
      described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5, deadline: 5)
    }.to raise_error(Docker::Error::TimeoutError, /deadline expired/)
  end

  # @spec LLM-ROUTING-013
  it "does not inspect the exit status after the upgraded stream exhausts its deadline" do
    connection = instance_double(Docker::Connection, url: "tcp://docker:2376", options: { timeout: 60 })
    start_connection = instance_double(Docker::Connection)
    container = instance_double(Docker::Container, id: "container-1", connection: connection)
    execution = instance_double(Docker::Exec, id: "exec-1")
    active_connection = connection
    allow(container).to receive(:connection) { active_connection }
    allow(container).to receive(:connection=) { |selected| active_connection = selected }
    allow(described_class::DeadlineConnection).to receive(:new).and_return(start_connection)
    allow(Docker::Exec).to receive(:create).and_return(execution)
    allow(execution).to receive(:json)
    allow(start_connection).to receive(:post)
    allow(described_class).to receive(:monotonic_now).and_return(100.0, 100.0, 100.0, 105.0)

    expect {
      described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5, deadline: 5)
    }.to raise_error(Docker::Error::TimeoutError, /deadline expired/)

    expect(execution).not_to have_received(:json)
  end

  # @spec LLM-ROUTING-013
  it "recomputes the deadline for every HTTP request within exec creation" do
    connection = instance_double(Docker::Connection, url: "tcp://docker:2376", options: { timeout: 60 })
    deadline_connection = described_class::DeadlineConnection.new(connection, 105.0)
    transport = instance_double(Docker::Connection)
    allow(Docker::Connection).to receive(:new).and_return(transport)
    allow(transport).to receive(:request)
    allow(described_class).to receive(:monotonic_now).and_return(101.0, 103.0)

    deadline_connection.request(:get, "/version")
    deadline_connection.request(:post, "/containers/container-1/exec")

    expect(Docker::Connection).to have_received(:new).with("tcp://docker:2376", timeout: 4.0, retry_limit: 0)
    expect(Docker::Connection).to have_received(:new).with("tcp://docker:2376", timeout: 2.0, retry_limit: 0)
  end

  # @spec LLM-ROUTING-013
  it "interrupts a silent upgraded stream at the shared deadline" do
    connection = instance_double(Docker::Connection, url: "tcp://docker:2376", options: { timeout: 60 })
    create_connection = instance_double(Docker::Connection)
    start_connection = instance_double(Docker::Connection)
    container = instance_double(Docker::Container, id: "container-1", connection: connection)
    execution = instance_double(Docker::Exec, id: "exec-1", json: { "ExitCode" => 0 })
    socket = instance_double(IO)
    active_connection = connection
    allow(container).to receive(:connection) { active_connection }
    allow(container).to receive(:connection=) { |selected| active_connection = selected }
    allow(Docker::Connection).to receive(:new).and_return(create_connection, start_connection)
    allow(Docker::Exec).to receive(:create).and_return(execution)
    allow(socket).to receive_messages(write: 5, close: nil)
    allow(start_connection).to receive(:post) { |_path, _query, options| options.fetch(:hijack_block).call(socket) }
    allow(IO).to receive(:select).and_return(nil)
    allow(described_class).to receive(:monotonic_now).and_return(100.0, 100.0, 100.0, 100.0, 105.0)

    expect {
      described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5, deadline: 5)
    }.to raise_error(Docker::Error::TimeoutError, /deadline expired/)

    expect(socket).to have_received(:close)
  end

  describe "wrapped transport errors" do
    let(:connection) { instance_double(Docker::Connection) }
    let(:container) { instance_double(Docker::Container, id: "container-1", connection: connection) }
    let(:execution) { instance_double(Docker::Exec, id: "exec-1") }
    let(:socket_error) { Excon::Error::Socket.new(IOError.new("upgraded stream failed")) }

    before do
      allow(Docker::Exec).to receive(:create).and_return(execution)
    end

    # @spec LLM-ROUTING-013
    it "preserves the Docker timeout type across the HTTP upgrade wrapper" do
      original_error = Docker::Error::TimeoutError.new("Docker operation deadline expired")
      allow(connection).to receive(:post) { raise socket_error, cause: original_error }

      expect {
        described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5)
      }.to raise_error { |error| expect(error).to equal(original_error) }
    end

    # @spec LLM-ROUTING-013
    it "preserves unrelated socket failures without classifying them as timeouts" do
      original_error = IOError.new("connection failed")
      allow(connection).to receive(:post) { raise socket_error, cause: original_error }

      expect {
        described_class.call(container:, command: [ "cat" ], stdin: StringIO.new("input"), wait: 5)
      }.to raise_error { |error| expect(error).to equal(socket_error) }
    end
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
