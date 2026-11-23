# frozen_string_literal: true

require "docker-api"

module Containers
  # docker-api's exec stdin path omits the HTTP upgrade headers. Docker can
  # return before the command completes, leaving its exit status unavailable.
  # Input is length-framed; EOF-driven commands cannot use this transport.
  # @spec LLM-ROUTING-006 LLM-ROUTING-013
  class DockerExecWithStdin
    def self.call(container:, command:, stdin:, wait:, deadline: nil, **options, &block)
      absolute_deadline = deadline && monotonic_now + deadline
      execution = with_deadline(container, absolute_deadline) do
        Docker::Exec.create(exec_config(container, command, options), container.connection)
      end
      messages = Docker::Messages.new
      with_deadline(container, absolute_deadline) do |remaining|
        container.connection.post("/exec/#{execution.id}/start", nil,
          body: { Tty: false, Detach: false }.to_json,
          headers: { "Connection" => "Upgrade", "Upgrade" => "tcp" },
          expects: [ 101 ], read_timeout: [ wait, remaining ].compact.min,
          hijack_block: stream_input(stdin, messages, deadline: absolute_deadline, &block))
      end
      [ messages.stdout_messages, messages.stderr_messages, execution.json["ExitCode"] ]
    end

    def self.exec_config(container, command, options)
      {
        "Container" => container.id,
        "Cmd" => command,
        "AttachStdin" => true,
        "AttachStdout" => true,
        "AttachStderr" => true,
        "Tty" => false
      }.merge(options)
    end
    private_class_method :exec_config

    def self.with_deadline(container, absolute_deadline)
      return yield unless absolute_deadline

      remaining = absolute_deadline - monotonic_now
      raise Docker::Error::TimeoutError, "Docker operation deadline expired" unless remaining.positive?

      original_connection = container.connection
      container.connection = deadline_connection(original_connection, remaining)
      yield remaining
    ensure
      container.connection = original_connection if original_connection
    end
    private_class_method :with_deadline

    def self.deadline_connection(connection, remaining)
      Docker::Connection.new(connection.url, connection.options.merge(timeout: remaining, retry_limit: 0))
    end
    private_class_method :deadline_connection

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_now

    def self.stream_input(stdin, messages, deadline: nil, &block)
      attach = Docker::Util.attach_for(block, messages, false)
      lambda do |socket|
        # The materializer reads a declared byte count. Half-closing this
        # socket makes Docker end the attached stream before a quiet command
        # finishes, so leave the write side open until Docker closes it.
        writer = Thread.new { copy_input(stdin, socket) }
        begin
          loop { attach.call(read_stream(socket, deadline), nil, nil) }
        rescue EOFError
          nil
        ensure
          socket.close if deadline_expired?(deadline)
          writer.join
          writer.value
        end
      end
    end
    private_class_method :stream_input

    def self.read_stream(socket, deadline)
      return socket.readpartial(512) unless deadline

      remaining = deadline - monotonic_now
      raise Docker::Error::TimeoutError, "Docker operation deadline expired" unless remaining.positive?

      raise Docker::Error::TimeoutError, "Docker operation deadline expired" unless IO.select([ socket ], nil, nil, remaining)

      socket.read_nonblock(512)
    rescue IO::WaitReadable
      retry
    end
    private_class_method :read_stream

    def self.deadline_expired?(deadline)
      deadline && monotonic_now >= deadline
    end
    private_class_method :deadline_expired?

    def self.copy_input(stdin, socket)
      IO.copy_stream(stdin, socket)
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      # A command may exit without consuming its complete input. Docker closes
      # the write side in that case, but the completed exec status remains the
      # authoritative result.
      nil
    end
    private_class_method :copy_input
  end
end
