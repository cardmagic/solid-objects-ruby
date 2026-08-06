# rbs_inline: enabled

class ChatRoomActor < SolidObjects::Actor
  MAX_RECENT_MESSAGES = 100

  attribute :members, default: -> { [] }
  attribute :recent_messages, default: -> { [] }

  observable :presence do
    state.members.length
  end

  observable :recent_messages

  message :join do |user_id:|
    state.members << user_id unless state.members.include?(user_id)
  end

  message :leave do |user_id:|
    state.members.delete(user_id)
  end

  message :send_message do |message_id:, user_id:, body:|
    return if state.recent_messages.any? { |message| message.fetch("id") == message_id }
    return unless state.members.include?(user_id)

    state.recent_messages << {
      "id" => message_id,
      "user_id" => user_id,
      "body" => body
    }
    state.recent_messages.shift while state.recent_messages.length > MAX_RECENT_MESSAGES
  end

  query :recent_messages do
    state.recent_messages
  end
end
