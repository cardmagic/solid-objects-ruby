# frozen_string_literal: true

require "database_test_helper"

class BackgroundPickupTest < ActiveSupport::TestCase
  class MailboxActor < SolidObjects::Actor
    actor_type "background-pickup-mailbox"

    attribute :delivered, default: 0

    def receive
      self.delivered += 1
    end
  end

  test "leaves an async message ready until a worker runs the roles" do
    message = MailboxActor.ref("inbox").async.receive

    assert_equal "ready", message.status
    assert_empty SolidObjects::Instance.find_by!(
      actor_type: "background-pickup-mailbox", actor_id: "inbox"
    ).state

    worker = SolidObjects::Worker.new
    begin
      worker.run_until_idle
    ensure
      worker.stop
    end

    assert_equal "completed", message.status
    assert_equal(
      { "delivered" => 1 },
      SolidObjects::Instance.find_by!(actor_type: "background-pickup-mailbox", actor_id: "inbox").state
    )
  end
end
