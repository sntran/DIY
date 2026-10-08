defmodule DIY.ApplicationTest do
  use ExUnit.Case, async: true

  test "a change of the configuration goes to the endpoint" do
    assert DIY.Application.config_change([], [], []) == :ok
  end
end
