# frozen_string_literal: true

# The macOS host connection is deployment configuration, so every web and job
# process independently builds the reconciliation runner after boot/reload.
Rails.application.config.to_prepare do
  AppleVerification::TartRunner.register_from_environment!
end
