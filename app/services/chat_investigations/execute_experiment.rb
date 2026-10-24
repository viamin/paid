# frozen_string_literal: true

module ChatInvestigations
  # Executes an experiment investigation's prompt inside the question's
  # isolated chat workspace through the agent-harness execution plan
  # (Containers::ChatSessionManager) and retains the bounded output as
  # reconnectable evidence on the investigation. Workspace readiness alone is
  # never reported as experimental evidence; the recorded exit status and
  # output are the experiment's result. A runtime failure after output has
  # streamed keeps that partial output and settles through the same failed
  # path as a non-zero exit.
  class ExecuteExperiment
    MAX_OUTPUT_BYTES = 100 * 1024
    MAX_RUNTIME_ERROR_BYTES = 500
    EXECUTION_TIMEOUT = 10.minutes

    Execution = Data.define(:exit_code, :stdout, :stderr, :session_id, :stdout_truncated, :stderr_truncated,
      :runtime_error) do
      def initialize(exit_code:, stdout:, stderr:, session_id:, stdout_truncated:, stderr_truncated:, runtime_error: nil)
        super
      end

      def success? = runtime_error.nil? && exit_code.zero?

      def result_text
        [ header, output_section, stderr_section, truncation_notice ].compact.join("\n\n")
      end

      private

      def header
        return "Experiment failed (runtime error: #{runtime_error})." if runtime_error

        success? ? "Experiment completed (exit code #{exit_code})." : "Experiment failed (exit code #{exit_code})."
      end

      def output_section
        "Output:\n#{stdout.rstrip}" if stdout.present?
      end

      def stderr_section
        "Stderr:\n#{stderr.rstrip}" if stderr.present?
      end

      def truncation_notice
        streams = []
        streams << "stdout truncated at #{MAX_OUTPUT_BYTES} bytes" if stdout_truncated
        streams << "stderr truncated at #{MAX_OUTPUT_BYTES} bytes" if stderr_truncated
        "[#{streams.join('; ')}]" if streams.any?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(investigation:)
      @investigation = investigation
    end

    def call
      execution = execute_prompt
      record_evidence(execution)
      execution
    end

    private

    attr_reader :investigation

    def execute_prompt
      result = Containers::ChatSessionManager.new(investigation.chat_session)
        .execute_agent_command(prompt: investigation.prompt, timeout: EXECUTION_TIMEOUT)
      Execution.new(
        exit_code: result[:exit_code].to_i,
        session_id: result[:session_id],
        **bounded_streams(result[:stdout], result[:stderr])
      )
    rescue Containers::ChatSessionManager::ExecutionError => e
      runtime_failed_execution(e)
    end

    # A runtime failure mid-stream (e.g. Docker daemon death) carries the
    # already-streamed output on the error; bound and retain it so the partial
    # experiment output and truncation evidence survive the failed settlement.
    def runtime_failed_execution(error)
      Execution.new(
        exit_code: nil,
        session_id: nil,
        runtime_error: error.message.truncate(MAX_RUNTIME_ERROR_BYTES),
        **bounded_streams(error.stdout, error.stderr)
      )
    end

    def bounded_streams(raw_stdout, raw_stderr)
      stdout, stdout_truncated = bounded_stream(raw_stdout)
      stderr, stderr_truncated = bounded_stream(raw_stderr)
      { stdout:, stderr:, stdout_truncated:, stderr_truncated: }
    end

    def bounded_stream(raw)
      text = Array(raw).join.force_encoding("UTF-8").scrub
      return [ text, false ] if text.bytesize <= MAX_OUTPUT_BYTES

      [ text.byteslice(0, MAX_OUTPUT_BYTES).scrub(""), true ]
    end

    # Written under the investigation lock so the evidence survives alongside
    # a concurrent cancellation's own metadata write, and stays attached to the
    # question for reconnecting collaborators.
    def record_evidence(execution)
      investigation.with_lock do
        investigation.update!(metadata: investigation.metadata.merge("experiment" => evidence_for(execution)))
      end
    end

    def evidence_for(execution)
      {
        "exit_code" => execution.exit_code,
        "stdout_truncated" => execution.stdout_truncated,
        "stderr_truncated" => execution.stderr_truncated,
        "agent_session_id" => execution.session_id,
        "runtime_error" => execution.runtime_error,
        "executed_at" => Time.current.iso8601
      }.compact
    end
  end
end
