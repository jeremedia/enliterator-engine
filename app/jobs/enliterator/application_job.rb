module Enliterator
  # Base for the engine's jobs. Queue is resolved at enqueue time from the host's
  # configuration so a host can route Enliterator work to its own queue without
  # patching the engine.
  class ApplicationJob < ActiveJob::Base
    queue_as { Enliterator.configuration.queue_name }
  end
end
