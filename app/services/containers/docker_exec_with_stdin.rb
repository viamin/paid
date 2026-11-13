# frozen_string_literal: true

require "docker-api"

module Containers
  # docker-api's exec stdin path omits the HTTP upgrade headers. Docker can
  # return before the command completes, leaving its exit status unavailable.
  # Input is length-framed; EOF-driven commands cannot use this transport.
  # @spec LLM-ROUTING-006
  class DockerExecWithStdin
    def self.call(container:, command:, stdin:, wait:, **options, &block)
      execution = Docker::Exec.create({
        "Container" => container.id,
        "Cmd" => command,
        "AttachStdin" => true,
        "AttachStdout" => true,
        "AttachStderr" => true,
        "Tty" => false
      }.merge(options), container.connection)
      messages = Docker::Messages.new
      container.connection.post("/exec/#{execution.id}/start", nil,
        body: { Tty: false, Detach: false }.to_json,
        headers: { "Connection" => "Upgrade", "Upgrade" => "tcp" },
        expects: [ 101 ], read_timeout: wait,
        hijack_block: stream_input(stdin, messages, &block))
      [ messages.stdout_messages, messages.stderr_messages, execution.json["ExitCode"] ]
    end

    def self.stream_input(stdin, messages, &block)
      attach = Docker::Util.attach_for(block, messages, false)
      lambda do |socket|
        # The materializer reads a declared byte count. Half-closing this
        # socket makes Docker end the attached stream before a quiet command
        # finishes, so leave the write side open until Docker closes it.
        writer = Thread.new { copy_input(stdin, socket) }
        begin
          loop { attach.call(socket.readpartial(512), nil, nil) }
        rescue EOFError
          nil
        ensure
          writer.join
          writer.value
        end
      end
    end
    private_class_method :stream_input

    def self.copy_input(stdin, socket)
      IO.copy_stream(stdin, socket)
    rescue Errno::EPIPE, Errno::ECONNRESET
      # A command may exit without consuming its complete input. Docker closes
      # the write side in that case, but the completed exec status remains the
      # authoritative result.
      nil
    end
    private_class_method :copy_input
  end
end
