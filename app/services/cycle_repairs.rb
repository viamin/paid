# frozen_string_literal: true

# Bounded, operator-confirmed repair of one persisted dependency-cycle
# occurrence. Durable repair evidence lives on the declaring GitHub issue and
# the ordinary dependency synchronization path; the workflow never edits more
# than the first witness-path edge's declaration.
module CycleRepairs
end
