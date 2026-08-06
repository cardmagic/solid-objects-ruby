# rbs_inline: enabled

class ChatRoomsController < ApplicationController
  # @rbs () -> void
  def show
    @room = current_room
  end

  # @rbs () -> void
  def join
    current_room.tell(
      :join,
      user_id: current_user.id.to_s,
      authorization_context: self
    )
    redirect_to chat_room_path(params[:id])
  end

  # @rbs () -> void
  def leave
    current_room.tell(
      :leave,
      user_id: current_user.id.to_s,
      authorization_context: self
    )
    redirect_to chat_room_path(params[:id])
  end

  # @rbs () -> void
  def create_message
    current_room.tell(
      :send_message,
      message_id: SecureRandom.uuid,
      user_id: current_user.id.to_s,
      body: params.require(:body),
      authorization_context: self
    )
    redirect_to chat_room_path(params[:id])
  end

  private

  # @rbs () -> SolidObjects::Reference
  def current_room
    ChatRoomActor.ref(params.require(:id))
  end
end
