defmodule Membrane.Core.Element.StateSpec do
  use ESpec, async: true
  alias Membrane.Support.Element.TrivialFilter
  alias Membrane.Core.Playback
  alias Membrane.Core.Element.PlaybackBuffer

  describe "new/2" do
    it "should create proper state" do
      state = described_module().new(TrivialFilter, :name)

      expect(state)
      |> to(
        eq struct(
             described_module(),
             module: TrivialFilter,
             type: :filter,
             name: :name,
             internal_state: nil,
             pads: nil,
             watcher: nil,
             controlling_pid: nil,
             playback: %Playback{},
             playback_buffer: PlaybackBuffer.new(),
             delayed_demands: %{}
           )
      )
    end
  end
end
