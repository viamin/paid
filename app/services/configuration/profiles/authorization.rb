# frozen_string_literal: true

module Configuration
  module Profiles
    class Authorization
      LEVEL_POLICIES = {
        project: lambda do |actor:, context:|
          allowed = ProjectPolicy.new(actor, context.project).update?
          [ allowed, "Not authorized to update project settings" ]
        end,
        user: lambda do |actor:, context:|
          user_setting = context.user_setting
          return [ false, "No user settings target is available for this profile plan" ] if user_setting.blank?

          allowed = UserSettingPolicy.new(actor, user_setting).update?
          [ allowed, "Not authorized to update user settings" ]
        end,
        tenant: lambda do |actor:, context:|
          allowed = AccountPolicy.new(actor, context.project.account).update?
          [ allowed, "Not authorized to update tenant settings" ]
        end
      }.freeze

      def self.call(...)
        new(...).call
      end

      def initialize(actor:, context:, changes:)
        @actor = actor
        @context = context
        @changes = Array(changes)
      end

      def call
        changes_by_level.map do |level, level_changes|
          allowed, reason = LEVEL_POLICIES.fetch(level).call(actor:, context:)

          {
            "level" => level.to_s,
            "allowed" => allowed,
            "reason" => (reason unless allowed),
            "keys" => level_changes.map(&:key)
          }.compact
        end
      end

      private

      attr_reader :actor, :context, :changes

      def changes_by_level
        changes.group_by(&:level)
      end
    end
  end
end
