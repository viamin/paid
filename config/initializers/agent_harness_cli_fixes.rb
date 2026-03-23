# frozen_string_literal: true

# Patches agent-harness 0.5.0 provider build_command methods to use correct
# CLI argument syntax.  The gem passes `--prompt <text>` but the actual CLIs
# expect the prompt as a positional argument.
#
# Claude CLI:  claude --print --output-format=json "<prompt>"
# Codex CLI:   codex exec "<prompt>"
#
# Remove once agent-harness ships corrected build_command implementations.

Rails.application.config.after_initialize do
  # --- Anthropic (Claude Code CLI) -------------------------------------------
  if defined?(AgentHarness::Providers::Anthropic)
    AgentHarness::Providers::Anthropic.class_eval do
      protected

      def build_command(prompt, options)
        cmd = [ self.class.binary_name ]

        cmd += [ "--print", "--output-format=json" ]

        if @config.model && !@config.model.empty?
          cmd += [ "--model", @config.model ]
        end

        if options[:dangerous_mode] && supports_dangerous_mode?
          cmd += dangerous_mode_flags
        end

        cmd += @config.default_flags if @config.default_flags&.any?

        # Prompt is a positional argument, not --prompt
        cmd << prompt

        cmd
      end
    end
  end

  # --- Codex -----------------------------------------------------------------
  if defined?(AgentHarness::Providers::Codex)
    AgentHarness::Providers::Codex.class_eval do
      protected

      def build_command(prompt, options)
        # Use `codex exec` subcommand for non-interactive execution
        cmd = [ self.class.binary_name, "exec" ]

        if options[:session]
          cmd += session_flags(options[:session])
        end

        # Prompt is a positional argument, not --prompt
        cmd << prompt

        cmd
      end
    end
  end
end
