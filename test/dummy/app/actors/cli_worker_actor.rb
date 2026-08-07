# frozen_string_literal: true

class CliWorkerActor < SolidObjects::Actor
  attribute :completed, default: false

  def complete
    self.completed = true
  end
end
