# frozen_string_literal: true

module PromptAssembly
  # Declares how sections are ordered, which optional sections are disabled,
  # and whether the profile may override safety-sensitive sections.
  #
  # Ordinary profiles (the default) cannot disable safety sections; only a
  # profile explicitly authorized via +allow_safety_overrides+ may. Budgets
  # are declared for forward compatibility and are not enforced in Phase 1.
  class Profile
    attr_reader :name, :order, :disabled_keys, :budgets, :allow_safety_overrides

    def initialize(name:, order: [], disabled_keys: [], budgets: {},
                   allow_safety_overrides: false)
      @name = name
      @order = order
      @disabled_keys = disabled_keys
      @budgets = budgets
      @allow_safety_overrides = allow_safety_overrides
    end

    def disabled?(key)
      disabled_keys.include?(key.to_s)
    end

    def safety_overrides_allowed?
      allow_safety_overrides
    end
  end
end
