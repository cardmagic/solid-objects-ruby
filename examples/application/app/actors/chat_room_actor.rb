# rbs_inline: enabled

class ChatRoomActor < SolidObjects::Actor
  MAX_RECENT_MESSAGES = 100

  attribute :members, default: -> { [] }
  attribute :recent_messages, default: -> { [] }

  observable :presence, broadcast: :value do
    members.length
  end

  observable :recent_messages

  def join(user_id:)
    members << user_id unless members.include?(user_id)
  end

  def leave(user_id:)
    members.delete(user_id)
  end

  def send_message(message_id:, user_id:, body:)
    return if recent_messages.any? { |message| message.fetch("id") == message_id }
    return unless members.include?(user_id)

    recent_messages << {
      "id" => message_id,
      "user_id" => user_id,
      "body" => body
    }
    recent_messages.shift while recent_messages.length > MAX_RECENT_MESSAGES
  end
end
