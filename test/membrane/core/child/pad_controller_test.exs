defmodule Membrane.Core.Child.PadControllerTest do
  use ExUnit.Case, async: true

  alias Membrane.Core.Child.{PadModel, PadSpecHandler}
  alias Membrane.Core.Element.State
  alias Membrane.Core.Message
  alias Membrane.LinkError
  alias Membrane.Pad
  alias Membrane.Support.Element.{DynamicFilter, TrivialFilter, TrivialSink}

  require Message
  require Pad

  @module Membrane.Core.Child.PadController

  defp prepare_state(elem_module, name \\ :element, playback_state \\ :stopped) do
    %{name: name, module: elem_module, parent_clock: nil, sync: nil}
    |> State.new()
    |> Map.update!(:playback, &%{&1 | state: playback_state})
    |> PadSpecHandler.init_pads()
    |> Bunch.Access.put_in(:internal_state, %{})
    |> Bunch.Access.put_in(:watcher, self())
  end

  describe ".handle_link/7" do
    test "when pad is present in the element" do
      state = prepare_state(TrivialFilter)

      assert {{:ok, _pad_info}, new_state} =
               @module.handle_link(
                 :output,
                 %{pad_ref: :output, pid: self(), pad_props: []},
                 %{pad_ref: :other_input, pid: nil},
                 %{direction: :input, mode: :pull, demand_unit: :buffers},
                 state
               )

      assert %{new_state | pads: nil} == %{state | pads: nil}
      assert PadModel.assert_instance(new_state, :output) == :ok
    end

    test "when pad is does not exist in the element" do
      state = prepare_state(TrivialFilter)

      assert_raise LinkError, fn ->
        @module.handle_link(:output, %{pad_ref: :invalid_pad_ref}, %{}, %{}, state)
      end
    end
  end

  defp prepare_static_state(elem_module, name, pad_name, playback_state) do
    {info, state} =
      elem_module
      |> prepare_state(name)
      |> Bunch.Access.pop_in([:pads, :info, pad_name])

    data =
      %Pad.Data{
        start_of_stream?: true,
        end_of_stream?: false
      }
      |> Map.merge(info)

    state
    |> Bunch.Access.put_in([:pads, :data, pad_name], data)
    |> Bunch.Struct.put_in([:playback, :state], playback_state)
  end

  defp prepare_dynamic_state(elem_module, name, playback_state, pad_name, pad_ref) do
    state = elem_module |> prepare_state(name, playback_state)
    info = state.pads.info[pad_name]

    data =
      %Pad.Data{
        start_of_stream?: true,
        end_of_stream?: false
      }
      |> Map.merge(info)

    state |> Bunch.Access.put_in([:pads, :data, pad_ref], data)
  end

  describe "handle_unlink" do
    test "for public static output pad (stopped)" do
      state = prepare_static_state(TrivialFilter, :element, :output, :stopped)
      assert state.pads.data |> Map.has_key?(:output)
      assert {:ok, new_state} = @module.handle_unlink(:output, state)
      refute new_state.pads.data |> Map.has_key?(:output)
    end

    test "for public static input pad (stopped)" do
      state = prepare_static_state(TrivialSink, :element, :input, :stopped)
      assert state.pads.data |> Map.has_key?(:input)
      assert {:ok, new_state} = @module.handle_unlink(:input, state)
      refute new_state.pads.data |> Map.has_key?(:input)
    end

    test "for dynamic input pad" do
      pad_ref = Pad.ref(:input, 0)
      state = prepare_dynamic_state(DynamicFilter, :element, :playing, :input, pad_ref)
      assert state.pads.data |> Map.has_key?(pad_ref)
      assert {:ok, new_state} = @module.handle_unlink(pad_ref, state)
      assert new_state.internal_state[:last_event] == nil
      assert new_state.internal_state.last_pad_removed == pad_ref
      refute new_state.pads.data |> Map.has_key?(pad_ref)
    end
  end
end
