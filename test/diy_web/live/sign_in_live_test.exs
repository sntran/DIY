defmodule DIYWeb.SignInLiveTest do
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIYWeb.HomeAssistant

  defp status(view, payload), do: render_hook(view, "ha:status", payload)

  test "the sign-in page has the hook, and shows each step of the sign-in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ha/sign-in?#{[url: "https://ha.example.com", id: "s1"]}")
    assert page_title(view) == "Sign in to Home Assistant"
    assert has_element?(view, "#ha-sign-in[phx-hook=HomeAssistantSignIn] h1", "Sign in")
    # The page needs no build: no bar of the parts of a build.
    refute has_element?(view, "nav.dock")
    assert has_element?(view, "#ha-status[role=status]", "The app gets ready for the sign-in.")
    refute has_element?(view, "#ha-error")
    refute has_element?(view, "#ha-close")

    status(view, %{"state" => "signing_in", "url" => "https://ha.example.com"})

    assert has_element?(
             view,
             "#ha-status",
             "The app signs in to Home Assistant at https://ha.example.com."
           )

    status(view, %{"state" => "done", "url" => "https://ha.example.com"})
    assert has_element?(view, "#ha-status", "The sign-in is done.")
    assert has_element?(view, "#ha-close", "You can close this tab.")
    refute has_element?(view, "#ha-error")

    status(view, %{"state" => "none", "url" => "https://ha.example.com", "error" => "denied"})
    assert has_element?(view, "#ha-status", "The sign-in did not finish.")
    assert has_element?(view, "#ha-error[role=alert]", "Home Assistant did not give access.")
    assert has_element?(view, "#ha-close")

    status(view, %{"state" => "none", "error" => "cancelled"})
    assert has_element?(view, "#ha-error", "A disconnect stopped this sign-in.")

    # A page that no tab of the app opened, or a page that the person
    # loaded again: no field of the address on this page.
    status(view, %{"state" => "none", "error" => "unasked"})
    assert has_element?(view, "#ha-error", "Only the key Connect of the app can start a sign-in.")
    status(view, %{"state" => "none", "error" => "url"})
    assert has_element?(view, "#ha-error", "Connect again on the page of the app.")
    refute has_element?(view, "#ha-error", "Give the address")

    # The states of a page of the app change nothing here.
    status(view, %{"state" => "connected", "url" => "https://ha.example.com"})
    assert has_element?(view, "#ha-status", "The sign-in did not finish.")
  end

  # The page takes only the states and the errors that it knows, and texts
  # of a limited length. Each status shows one of its known texts.
  property "a status that the page cannot read shows no unknown text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ha/sign-in")
    known = ~w(none signing_in done)
    others = ~w(connecting connected offline signed_out)

    errors =
      ~w(url blocked tab closed cancelled unasked state denied token unreachable storage signed_out)

    check all(
            state <-
              one_of([
                member_of(known),
                member_of(others),
                string(:printable, max_length: 12),
                integer()
              ]),
            error <-
              one_of([member_of(errors), string(:printable, max_length: 12), constant(nil)]),
            url <-
              one_of([
                constant("https://ha.example.com"),
                string(:alphanumeric, min_length: 2049, max_length: 2100)
              ]),
            max_runs: 60
          ) do
      # A known state first: the page shows no error.
      status(view, %{"state" => "none"})
      before = view |> element("#ha-status") |> render()
      status(view, %{"state" => state, "url" => url, "error" => error})
      text = view |> element("#ha-status") |> render()

      if state in known do
        ha = %{state: state, url: if(byte_size(url) <= 2048, do: url), error: nil}

        assert text =~
                 ha
                 |> HomeAssistant.tab_status()
                 |> Phoenix.HTML.html_escape()
                 |> Phoenix.HTML.safe_to_string()

        if byte_size(url) > 2048, do: refute(text =~ url)
        assert has_element?(view, "#ha-error") == error in errors
      else
        assert text == before
        refute has_element?(view, "#ha-error")
      end
    end
  end
end
