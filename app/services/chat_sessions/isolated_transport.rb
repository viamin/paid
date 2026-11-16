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

      class DeadlineCancellation
        def initialize(deadline:)
          @deadline = deadline
        end

        def cancelled?
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
        end
      end

      def symbolize(value)
        case value
        when Array then value.map { |item| symbolize(item) }
        when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
        else value
        end
      end

      request = symbolize(JSON.parse(STDIN.read))
      credential_env = request.delete(:credential_env)
      deadline = request.delete(:deadline)
      request[:cancellation] = DeadlineCancellation.new(deadline: deadline) if deadline
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
      @result = nil
      @stdout = +""
      @observer = observer
      timeout = timeout_for(request)
      raise AgentHarness::TimeoutError, "Isolated chat request deadline expired" unless timeout.positive?

      executor(timeout, deadline_for(request)).execute([ "ruby", "-e", RUNNER ], timeout: timeout, env: credential_env,
        stdin_data: serialized_request(request), output_observer: method(:receive_output))
      process_lines
      response = @result || raise(AgentHarness::ProviderError, "Isolated chat execution returned no result")
      normalize_response(response)
    ensure
      @executor&.close
      @executor = nil
    end

    private

    def executor(timeout, deadline)
      @executor ||= Containers::StandaloneTextExecutor.new(account: @chat_session.account, runner: @runner,
        timeout: timeout, deadline: deadline)
    end

    def timeout_for(request)
      # The harness running inside the container enforces the shorter read
      # deadline. The executor owns only the outer wall-clock bound so an
      # actively streaming response is not cut off after one read interval.
      deadline = deadline_for(request)
      return 10.minutes.in_seconds unless deadline

      deadline - monotonic_now
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
      cancellation = sanitized.delete(:cancellation)
      sanitized[:candidates].each { |candidate| candidate.delete(:credentials) }
      sanitized[:credential_env] = credential_env_name
      sanitized[:deadline] = cancellation.deadline if cancellation.respond_to?(:deadline)
      sanitized.to_json
    end

    def deadline_for(request)
      request[:cancellation]&.deadline
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

    def normalize_response(response)
      response.deep_symbolize_keys.tap do |normalized|
        normalized[:status] = normalized[:status].to_sym if normalized[:status].respond_to?(:to_sym)
        normalized[:error]&.tap do |error|
          error[:category] = error[:category].to_sym if error[:category].respond_to?(:to_sym)
          error[:code] = error[:code].to_sym if error[:code].respond_to?(:to_sym)
        end
      end
    end
  end
end
