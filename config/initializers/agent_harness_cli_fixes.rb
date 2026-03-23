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
  spec = Gem.loaded_specs["agent-harness"]
  version = spec&.version

  unless version == Gem::Version.new("0.5.0")
    Rails.logger.info(
      "[agent_harness_cli_fixes] Skipping patches: agent-harness #{version || 'not installed'} " \
      "(only 0.5.0 needs patching)"
    )
    next
  end

  # --- Anthropic (Claude Code CLI) -------------------------------------------
  begin
    # Reference the constant to trigger autoload if needed
    provider = AgentHarness::Providers::Anthropic

    provider.class_eval do
      alias_method :original_build_command, :build_command

      protected

      def build_command(prompt, options)
        cmd = original_build_command(prompt, options)

        # Replace --prompt <text> with positional prompt argument
        if (idx = cmd.index("--prompt"))
          cmd.delete_at(idx) # remove --prompt flag
          cmd.delete_at(idx) # remove the prompt value that followed it
        end

        cmd << prompt
        cmd
      end
    end

    Rails.logger.info("[agent_harness_cli_fixes] Patched AgentHarness::Providers::Anthropic#build_command")
  rescue NameError
    Rails.logger.info(
      "[agent_harness_cli_fixes] Skipping Anthropic patch: provider constant not defined"
    )
  rescue StandardError => e
    Rails.logger.warn(
      "[agent_harness_cli_fixes] Failed to patch Anthropic: #{e.class}: #{e.message}"
    )
  end

  # --- Codex -----------------------------------------------------------------
  begin
    provider = AgentHarness::Providers::Codex

    provider.class_eval do
      alias_method :original_build_command, :build_command

      protected

      def build_command(prompt, options)
        cmd = original_build_command(prompt, options)

        # Insert `exec` subcommand after binary name for non-interactive execution
        cmd.insert(1, "exec") unless cmd[1] == "exec"

        # Replace --prompt <text> with positional prompt argument
        if (idx = cmd.index("--prompt"))
          cmd.delete_at(idx) # remove --prompt flag
          cmd.delete_at(idx) # remove the prompt value that followed it
        end

        cmd << prompt
        cmd
      end
    end

    Rails.logger.info("[agent_harness_cli_fixes] Patched AgentHarness::Providers::Codex#build_command")
  rescue NameError
    Rails.logger.info(
      "[agent_harness_cli_fixes] Skipping Codex patch: provider constant not defined"
    )
  rescue StandardError => e
    Rails.logger.warn(
      "[agent_harness_cli_fixes] Failed to patch Codex: #{e.class}: #{e.message}"
    )
  end
end
