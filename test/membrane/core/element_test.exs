defmodule Membrane.Core.ElementTest do
  use ExUnit.Case, async: true

  alias __MODULE__.SomeElement
  alias Membrane.Core.Element
  alias Membrane.Core.Message

  require Membrane.Core.Message

  defmodule SomeElement do
    use Membrane.Source
    def_output_pad :output, caps: :any

    @impl true
    def handle_other(msg, _ctx, state) do
      {{:ok, notify: msg}, state}
    end
  end

  defmodule Filter do
    use Membrane.Filter

    def_output_pad :output, caps: :any

    def_input_pad :input, caps: :any, demand_unit: :buffers

    @impl true
    def handle_tick(_timer, _ctx, state) do
      {:ok, state}
    end

    @impl true
    def handle_demand(:output, size, _unit, _ctx, state) do
      {{:ok, demand: {:input, size}}, state}
    end
  end

  defp get_state do
    {:ok, state} =
      Element.init(%{
        module: Filter,
        user_options: nil,
        name: :some_element,
        parent_clock: nil,
        sync: Membrane.Sync.no_sync(),
        parent: self(),
        log_metadata: []
      })

    state
  end

  defp linked_state do
    {:reply, {:ok, _reply}, state} =
      Element.handle_call(
        Message.new(:handle_link, [
          :output,
          %{pad_ref: :output, pad_props: []},
          %{pad_ref: :input, pid: self()},
          %{direction: :input, mode: :pull, demand_unit: :buffers}
        ]),
        nil,
        get_state()
      )

    {:reply, {:ok, _reply}, state} =
      Element.handle_call(
        Message.new(:handle_link, [
          :input,
          %{pad_ref: :input, pad_props: []},
          %{pad_ref: :output, pid: self()},
          %{direction: :output, mode: :pull}
        ]),
        nil,
        state
      )

    {:reply, :ok, state} = Element.handle_call(Message.new(:linking_finished), nil, state)

    state
  end

  defp playing_state do
    {:noreply, state} =
      Element.handle_info(Message.new(:change_playback_state, :playing), linked_state())

    state
  end

  test "should change playback state" do
    assert {:noreply, state} =
             Element.handle_info(
               Message.new(:change_playback_state, :prepared),
               get_state()
             )

    assert state.playback.state == :prepared

    assert {:noreply, state} =
             Element.handle_info(Message.new(:change_playback_state, :playing), state)

    assert state.playback.state == :playing

    assert {:noreply, state} =
             Element.handle_info(Message.new(:change_playback_state, :prepared), state)

    assert state.playback.state == :prepared

    assert {:noreply, state} =
             Element.handle_info(Message.new(:change_playback_state, :stopped), state)

    assert state.playback.state == :stopped

    assert {:noreply, state} =
             Element.handle_info(Message.new(:change_playback_state, :playing), state)

    assert state.playback.state == :playing
  end

  test "should update watcher and reply as expected" do
    assert {:reply, {:ok, reply}, state} =
             Element.handle_call(
               Message.new(:handle_watcher, :c.pid(0, 255, 0)),
               nil,
               get_state()
             )

    assert reply == %{clock: state.synchronization.clock}
    assert state.watcher == :c.pid(0, 255, 0)
  end

  test "should set controlling pid" do
    assert {:reply, :ok, state} =
             Element.handle_call(
               Message.new(:set_controlling_pid, :c.pid(0, 255, 0)),
               nil,
               get_state()
             )

    assert state.controlling_pid == :c.pid(0, 255, 0)
  end

  test "should store demand/buffer/caps/event when not playing" do
    initial_state = linked_state()

    [
      Message.new(:demand, 10, for_pad: :output),
      Message.new(:buffer, [%Membrane.Buffer{payload: <<>>}], for_pad: :input),
      Message.new(:caps, :caps, for_pad: :input),
      Message.new(:event, %Membrane.Testing.Event{}, for_pad: :input),
      Message.new(:event, %Membrane.Testing.Event{}, for_pad: :output)
    ]
    |> Enum.each(fn msg ->
      assert {:noreply, state} = Element.handle_info(msg, initial_state)
      assert {:ok, state} == Element.PlaybackBuffer.store(msg, initial_state)
    end)
  end

  test "should update demand" do
    msg = Message.new(:demand, 10, for_pad: :output)
    assert {:noreply, state} = Element.handle_info(msg, playing_state())
    assert state.pads.data.output.demand == 10
  end

  test "should store incoming buffers in input buffer" do
    msg = Message.new(:buffer, [%Membrane.Buffer{payload: <<123>>}], for_pad: :input)
    assert {:noreply, state} = Element.handle_info(msg, playing_state())
    assert state.pads.data.input.input_buf.current_size == 1
  end

  test "should assign incoming caps to the pad and forward them" do
    assert {:noreply, state} =
             Element.handle_info(Message.new(:caps, :caps, for_pad: :input), playing_state())

    assert state.pads.data.input.caps == :caps
    assert state.pads.data.output.caps == :caps

    assert_receive Message.new(:caps, :caps, for_pad: :input)
  end

  test "should forward events" do
    [
      Message.new(:event, %Membrane.Testing.Event{}, for_pad: :input),
      Message.new(:event, %Membrane.Testing.Event{}, for_pad: :output)
    ]
    |> Enum.each(fn msg ->
      assert {:noreply, _state} = Element.handle_info(msg, playing_state())
      assert_receive ^msg
    end)
  end

  test "should handle linking pads and reply with pad info" do
    pid = self()

    assert {:reply, {:ok, reply}, state} =
             Element.handle_call(
               Message.new(:handle_link, [
                 :output,
                 %{pad_ref: :output, pad_props: []},
                 %{pad_ref: :input, pid: pid},
                 %{direction: :input, mode: :pull, demand_unit: :buffers}
               ]),
               nil,
               get_state()
             )

    assert reply == %{
             accepted_caps: :any,
             availability: :always,
             direction: :output,
             mode: :pull,
             name: :output,
             options: nil
           }

    assert %Membrane.Pad.Data{pid: ^pid, other_ref: :input, other_demand_unit: :buffers} =
             state.pads.data.output

    assert {:reply, :ok, _state} = Element.handle_call(Message.new(:linking_finished), nil, state)
  end

  test "should handle unlinking pads" do
    assert {:noreply, state} =
             Element.handle_info(Message.new(:handle_unlink, :input), linked_state())

    refute Map.has_key?(state.pads.data, :input)
  end

  test "should update timer on each tick" do
    {:ok, clock} = Membrane.Clock.start_link()
    {:ok, state} = Membrane.Core.TimerController.start_timer(:timer, 1000, clock, get_state())
    assert {:noreply, state} = Element.handle_info(Message.new(:timer_tick, :timer), state)
    assert state.synchronization.timers.timer.time_passed == 2000
  end

  test "should update clock ratio" do
    {:ok, clock} = Membrane.Clock.start_link()
    {:ok, state} = Membrane.Core.TimerController.start_timer(:timer, 1000, clock, get_state())

    assert {:noreply, state} = Element.handle_info({:membrane_clock_ratio, clock, 123}, state)

    assert state.synchronization.timers.timer.ratio == 123
  end

  test "should set stream sync" do
    assert {:reply, :ok, state} =
             Element.handle_call(Message.new(:set_stream_sync, :sync), nil, get_state())

    assert state.synchronization.stream_sync == :sync
  end

  test "should fail on invalid message" do
    [
      Message.new(:abc),
      Message.new(:abc, :def),
      Message.new(:abc, :def, for_pad: :input)
    ]
    |> Enum.each(fn msg ->
      assert {:stop, {:error, {:cannot_handle_message, {:invalid_message, ^msg, _}, _}}, _state} =
               Element.handle_info(msg, get_state())

      assert {:reply, {:error, {:cannot_handle_message, {:invalid_message, ^msg, _}, _}}, _state} =
               Element.handle_call(msg, nil, get_state())
    end)

    assert {:reply, {:error, {:cannot_handle_message, {:invalid_message, :abc, _}, _}}, _state} =
             Element.handle_call(:abc, nil, get_state())
  end

  test "other message" do
    state = get_state()
    assert {:noreply, state} == Element.handle_info(:abc, state)
  end

  describe "Not linked element" do
    test "should shutdown when pipeline is down" do
      pipeline_mock = spawn(fn -> receive do: (:exit -> :ok) end)

      {:ok, elem_pid} =
        pipeline_mock
        |> element_init_options
        |> Element.start()

      {:ok, _clock} = Message.call(elem_pid, :handle_watcher, pipeline_mock)
      ref = Process.monitor(elem_pid)
      send(pipeline_mock, :exit)
      assert_receive {:DOWN, ^ref, :process, ^elem_pid, {:shutdown, :parent_crash}}
    end

    test "should not assume pipeline is down when getting any monitor message" do
      monitored_proc = spawn(fn -> receive do: (:exit -> :ok) end)
      on_exit(fn -> send(monitored_proc, :exit) end)

      {:ok, elem_pid} =
        monitored_proc
        |> element_init_options
        |> Element.start()

      {:ok, _clock} = Message.call(elem_pid, :handle_watcher, self())
      ref = make_ref()
      deceased_pid = self()
      send(elem_pid, {:DOWN, ref, :process, deceased_pid, :normal})

      assert_receive Message.new(:notification, [
                       :name,
                       {:DOWN, ^ref, :process, ^deceased_pid, :normal}
                     ])

      assert Process.alive?(elem_pid)
    end
  end

  defp element_init_options(pipeline) do
    %{
      module: SomeElement,
      name: :name,
      user_options: %{},
      parent: pipeline,
      parent_clock: nil,
      sync: Membrane.Sync.no_sync(),
      log_metadata: []
    }
  end
end
