##
# Copyright (C) 2021  Valentin Lorentz
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License version 3,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
###

ExUnit.start()
ExUnit.start(timeout: 5000)

Mox.defmock(MockHTTPoison, for: HTTPoison.Base)

Logger.configure(level: :info)

defmodule MockIrcConnWriter do
  use GenServer

  def start_link(args) do
    {test_pid} = args
    name = {:via, Registry, {M51.Registry, {test_pid, :irc_writer}}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(arg, _from, state) do
    {test_pid} = state
    send(test_pid, arg)
    {:reply, :ok, state}
  end
end

defmodule MockMatrixState do
  use Agent

  def start_link(args) do
    {test_pid} = args

    name = {:via, Registry, {M51.Registry, {test_pid, :matrix_state}}}

    Agent.start_link(
      fn ->
        %M51.MatrixClient.State{
          rooms: %{
            "!room_id:example.org" => %M51.Matrix.RoomState{
              synced: true,
              canonical_alias: "#existing_room:example.org",
              members: %{
                "user1:example.org" => %M51.Matrix.RoomMember{display_name: "user one"},
                "user2:example.com" => %M51.Matrix.RoomMember{}
              }
            }
          }
        }
      end,
      name: name
    )
  end
end
