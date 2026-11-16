# frozen_string_literal: true

module ChatSessions
  # Executes one normalized API chat transport request in a disposable text
  # container. Rails retains the chat loop and is therefore still the sole
  # authority for application tool dispatch and confirmation.
  class IsolatedTransport # @spec CHAT-ISOLATION-001
    RESULT_TYPE = "result"
    EVENT_TYPE = "event"

    RUNNER = <<~'RUBY'.freeze
      require "json"
      require "agent_harness"

      def symbolize(value)
        case value
        when Array then value.map { |item| symbolize(item) }
        when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
        else value
        end
      end

      request = symbolize(JSON.parse(STDIN.read))
      credential_env = request.delete(:credential_env)
      request[:candidates].each do |candidate|
        candidate[:credentials] = { api_key: ENV.fetch(credential_env) }
      end
      STDOUT.sync = true
      result = AgentHarness::Api::ChatTransport.new.call(request) do |event|
        puts JSON.generate(type: "event", payload: event)
      end
      puts JSON.generate(type: "result", payload: result)
    RUBY

    def initialize(chat_session:, runner:, api_key:, executor: nil)
      @chat_session = chat_session
      @runner = runner
      @api_key = api_key
      @executor = executor
      @stdout = +""
    end

    def call(request, &observer)
      @observer = observer
      executor.execute([ "ruby", "-e", RUNNER ], timeout: timeout_for(request), env: credential_env,
        stdin_data: serialized_request(request), output_observer: method(:receive_output))
      process_lines
      response = @result || raise(AgentHarness::ProviderError, "Isolated chat execution returned no result")
      response.deep_symbolize_keys.tap do |normalized|
        normalized[:status] = normalized[:status].to_sym if normalized[:status].respond_to?(:to_sym)
      end
    ensure
      executor.close
    end

    private

    def executor
      @executor ||= Containers::StandaloneTextExecutor.new(account: @chat_session.account, runner: @runner, timeout: 10.minutes)
    end

    def timeout_for(_request)
      # The harness running inside the container enforces the shorter read
      # deadline. The executor owns only the outer wall-clock bound so an
      # actively streaming response is not cut off after one read interval.
      10.minutes.in_seconds
    end

    def credential_env
      { credential_env_name => @api_key }
    end

    def credential_env_name
      provider = AgentHarness.provider_class(RunnerSupport.harness_runner_key_for(@runner.runner_key).to_sym)
        .new(config: AgentHarness.build_config(RunnerSupport.harness_runner_key_for(@runner.runner_key).to_sym))
      provider.api_key_env_var_names.first || "OPENAI_API_KEY"
    end

    def serialized_request(request)
      sanitized = request.deep_dup
      sanitized.delete(:cancellation)
      sanitized[:candidates].each { |candidate| candidate.delete(:credentials) }
      sanitized[:credential_env] = credential_env_name
      sanitized.to_json
    end

    def receive_output(stream, chunk)
      return unless stream == :stdout

      @stdout << chunk.to_s
      process_lines
    end

    def process_lines
      lines = @stdout.lines
      @stdout = lines.pop.to_s unless @stdout.end_with?("\n")
      @stdout = +"" if @stdout.end_with?("\n")
      lines.each do |line|
        packet = JSON.parse(line)
        case packet.fetch("type")
        when EVENT_TYPE then @observer&.call(packet.fetch("payload").deep_symbolize_keys)
        when RESULT_TYPE then @result = packet.fetch("payload")
        end
      rescue JSON::ParserError
        raise AgentHarness::ProviderError, "Isolated chat execution emitted malformed protocol output"
      end
    end
  end
end
