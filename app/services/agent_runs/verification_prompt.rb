# frozen_string_literal: true

require "json"
require "shellwords"

module AgentRuns
  # @spec LIVE-PREVIEW-005
  class VerificationPrompt
    RESULT_PATH = "tmp/paid-agent-verification.json".freeze
    APP_LOG_PATH = "tmp/paid-agent-verification-app.log".freeze
    APP_PID_PATH = "tmp/paid-agent-verification-app.pid".freeze

    Section = Data.define(:content, :fallback_result)

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, repo_path:)
      @agent_run = agent_run
      @repo_path = repo_path
    end

    def call
      return Section.new(content: "", fallback_result: nil) unless verification_applicable?

      runtime_plan = Screenshots::RuntimePlan.call(project: @agent_run.project, repo_path: @repo_path)
      fallback_result = runtime_plan.start_command_available? ? nil : missing_start_command_result(runtime_plan)

      Section.new(
        content: render_section(runtime_plan, fallback_result:),
        fallback_result:
      )
    rescue Screenshots::ConfigError => e
      Section.new(
        content: render_config_error_section(e),
        fallback_result: {
          "status" => "skipped",
          "reason" => "verification_configuration_invalid",
          "summary" => "Verification configuration could not be parsed automatically.",
          "details" => e.message
        }
      )
    end

    private

    def verification_applicable?
      @agent_run.create_pr_goal? && @agent_run.project.verification_enabled? && @repo_path.present?
    end

    def render_section(runtime_plan, fallback_result:)
      <<~SECTION

        # Interactive Verification

        Verification is enabled for this run. After you make the code changes, attempt an end-to-end self-check against the changed app before your final commit.

        Use the browser MCP tools meaningfully when the change has a browser-visible surface. At minimum, navigate to the app, exercise the changed flow when applicable, and record what you observed.

        Verification target:
        - App URL: `#{runtime_plan.base_url}`
        - Framework: `#{runtime_plan.framework || "unknown"}`
        - Setup commands: #{setup_commands_summary(runtime_plan)}
        - Preferred start command: #{start_command_summary(runtime_plan)}

        If you start the app yourself, use this pattern so the run captures a stable log file:

        ```bash
        mkdir -p tmp
        (#{launch_command_for(runtime_plan)}) > #{Shellwords.escape(APP_LOG_PATH)} 2>&1 &
        echo $! > #{Shellwords.escape(APP_PID_PATH)}
        ```

        Record the verification result by writing JSON to `#{RESULT_PATH}` before you finish:

        ```json
        {
          "status": "passed",
          "summary": "Short verification summary",
          "app_url": "#{runtime_plan.base_url}",
          "start_command": #{json_string_or_null(runtime_plan.start_command)},
          "used_browser_tools": true,
          "browser_steps": ["Opened the changed page", "Exercised the updated flow"],
          "changed_surfaces": ["List the user-visible area you checked"],
          "artifacts": [{"kind": "app_log", "path": "#{APP_LOG_PATH}"}]
        }
        ```

        Allowed `status` values:
        - `passed` when the app started and the interactive check succeeded
        - `failed` when startup or browser verification exposed a problem; include `reason`
        - `skipped` when verification could not run or was not applicable; include `reason`

        If the normal start command is unavailable, you may determine an equivalent command yourself. If verification still cannot run, write a `skipped` result explaining why.#{fallback_reason_sentence(fallback_result)}
      SECTION
    end

    def render_config_error_section(error)
      <<~SECTION

        # Interactive Verification

        Verification is enabled for this run, but the screenshot/preview configuration could not be parsed automatically:

        `#{error.message}`

        If you can still determine how to start the app and verify the changed surface with browser MCP tools, do so and write the result JSON to `#{RESULT_PATH}`.
        Otherwise, write a `skipped` result with `reason: "verification_configuration_invalid"` and include the parsing error in `details`.
      SECTION
    end

    def setup_commands_summary(runtime_plan)
      commands = Array(runtime_plan.setup_commands)
      return "`none`" if commands.empty?

      commands.map { |command| "`#{command}`" }.join(", ")
    end

    def start_command_summary(runtime_plan)
      command = runtime_plan.start_command
      command.present? ? "`#{command}`" : "`not auto-detected`"
    end

    def launch_command_for(runtime_plan)
      runtime_plan.start_command.presence || "YOUR_APP_START_COMMAND_HERE"
    end

    def missing_start_command_result(runtime_plan)
      {
        "status" => "skipped",
        "reason" => "app_start_command_unavailable",
        "summary" => "Paid could not determine an application start command for verification automatically.",
        "app_url" => runtime_plan.base_url
      }
    end

    def fallback_reason_sentence(fallback_result)
      return "" unless fallback_result.present?

      " If you do not write a result file, Paid will record `#{fallback_result["reason"]}` for this run."
    end

    def json_string_or_null(value)
      value.nil? ? "null" : JSON.generate(value)
    end
  end
end
