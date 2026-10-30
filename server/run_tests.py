"""Tests for the relay server. No game needed: clients are sockets speaking the mod's framing.

    python -I local/city-game-studio/server/run_tests.py

Each case gets its own port so a shutting-down server can never leak state into the next one.
"""
import json
import shutil
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import coop_server  # noqa: E402

BASE_PORT = 7501
PREFIX = coop_server.PREFIX


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return f"{len(body):0{PREFIX}d}".encode("ascii") + body


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buffer = b""

    def send(self, message):
        self.sock.sendall(frame(message))

    def receive(self, timeout=3.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if len(self.buffer) >= PREFIX:
                length = int(self.buffer[:PREFIX])
                if len(self.buffer) >= PREFIX + length:
                    body = self.buffer[PREFIX:PREFIX + length]
                    self.buffer = self.buffer[PREFIX + length:]
                    return json.loads(body.decode("utf-8"))
            self.sock.settimeout(max(0.05, deadline - time.time()))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                return None
            self.buffer += chunk
        return None

    def drain(self, seconds=0.6):
        """Collects every message that arrives within the window."""
        out = []
        deadline = time.time() + seconds
        while time.time() < deadline:
            message = self.receive(timeout=max(0.05, deadline - time.time()))
            if message is None:
                break
            out.append(message)
        return out

    def wait_for(self, kind, seconds=3.0):
        """Waits for one message of a kind and returns it, or None.

        Fixed sleeps are how this suite produced false failures: two cases asserted on state the relay
        had not been reached yet, and whether they passed depended on how busy the machine was. A test
        that waits for the condition is slower and honest; a test that sleeps and hopes is neither.
        """
        deadline = time.time() + seconds
        while time.time() < deadline:
            message = self.receive(timeout=max(0.05, deadline - time.time()))
            if message is None:
                return None
            if message.get("t") == kind:
                return message
        return None

    def close(self):
        self.sock.close()


def with_server(test, port, store_dir=None):
    server = coop_server.Server(port, None, "127.0.0.1", store_dir)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    time.sleep(0.3)
    try:
        test(server, port)
    finally:
        server.stop()
        thread.join(timeout=2.0)


def company(player_id, fanbase, note):
    return {"id": player_id, "name": "Studio " + player_id, "logo": None, "note": note,
            "fanbase": fanbase, "currency": 1000, "studios": 2}


# --- cases ---------------------------------------------------------------

def test_world_reaches_the_joiner(server, port):
    """The host's world is what a client boots from; it must arrive even on a later join."""
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    host.send({"t": "world", "models": {"date": "{\"raw_date\":1173}"}})
    time.sleep(0.2)

    first = Client(port)
    first.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    first.send({"t": "join_request", "player": "c1"})
    world = first.receive()
    assert world and world["t"] == "world", world
    assert world["models"]["date"] == "{\"raw_date\":1173}", world

    second = Client(port)
    second.send({"t": "role", "role": "client", "player": "c2", "name": "two"})
    second.send({"t": "join_request", "player": "c2"})
    world = second.receive()
    assert world and world["t"] == "world", world

    host.close()
    first.close()
    second.close()


def test_join_request_tells_the_host(server, port):
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    client.send({"t": "join_request", "player": "c1"})

    request = host.drain(1.0)
    assert any(m["t"] == "join_request" for m in request), request
    host.close()
    client.close()


def test_the_auto_flag_reaches_the_host(server, port):
    """A client that cannot show a lobby says so, and the host must hear it.

    The relay used to rebuild the join_request with only player and name, dropping `auto`. Every
    automated join then looked interactive, so the host offered a lobby nobody could press and the client
    sat in the main menu while the host's clock ran on - which looks exactly like a broken lobby.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    client.send({"t": "join_request", "player": "c1", "auto": True})

    requests = [m for m in host.drain(1.0) if m["t"] == "join_request"]
    assert requests, "the host heard no join request at all"
    assert requests[0].get("auto") is True, (
        "the auto flag was dropped on the way to the host: %s" % requests[0]
    )

    # And a manual join must not be turned into an automatic one.
    client.send({"t": "join_request", "player": "c1", "auto": False})
    later = [m for m in host.drain(1.0) if m["t"] == "join_request"]
    assert later and later[-1].get("auto") is False, later

    host.close()
    client.close()


def test_clock_is_broadcast_to_every_client(server, port):
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    one = Client(port)
    two = Client(port)
    one.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    two.send({"t": "role", "role": "client", "player": "c2", "name": "two"})
    time.sleep(0.3)

    host.send({"t": "clock", "raw_date": 1173, "speed": 1, "paused": True})

    for client in (one, two):
        seen = [m for m in client.drain(1.0) if m["t"] == "clock"]
        assert seen, "a client got no clock"
        assert seen[0]["speed"] == 1 and seen[0]["paused"] is True, seen

    host.close()
    one.close()
    two.close()


def test_client_company_goes_to_the_host_and_is_kept(server, port):
    """A client's company reaches the host and is also kept by the relay.

    It must not be fanned out to other clients - a client's raw traffic is none of their business - but
    the relay itself now keeps a copy. The host publishes the company table every few seconds, so for
    anything a player does between the last publish and the host leaving, the relay's own copy is the
    only record there will ever be.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    one = Client(port)
    two = Client(port)
    one.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    two.send({"t": "role", "role": "client", "player": "c2", "name": "two"})
    time.sleep(0.3)

    one.send({"t": "company", "company": company("c1", 5000, 62.5)})

    seen = [m for m in host.drain(0.8) if m["t"] == "company"]
    assert seen and seen[0]["company"]["id"] == "c1", seen

    kept = server.store.load("c1")
    assert kept is not None, "the relay did not keep the client's own company"
    assert kept["fanbase"] == 5000, kept

    leaked = [m for m in two.drain(0.4) if m["t"] == "company"]
    assert not leaked, f"a client saw another client's raw traffic: {leaked}"

    host.close()
    one.close()
    two.close()


def test_host_company_table_fans_out(server, port):
    """The host decides what everyone sees, and it is the only one that fans out."""
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    one = Client(port)
    two = Client(port)
    one.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    two.send({"t": "role", "role": "client", "player": "c2", "name": "two"})
    time.sleep(0.3)

    table = {"t": "companies", "companies": [company("h", 1, 90.0), company("c1", 2, 50.0)]}
    host.send(table)

    for client in (one, two):
        seen = [m for m in client.drain(1.0) if m["t"] == "companies"]
        assert seen, "company table did not reach a client"
        ids = [c["id"] for c in seen[0]["companies"]]
        assert ids == ["h", "c1"], seen

    host.close()
    one.close()
    two.close()


def test_no_host_means_an_answered_error(server, port):
    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    client.send({"t": "join_request", "player": "c1"})
    reply = client.receive()
    assert reply and reply["t"] == "error", reply
    assert "host" in reply["message"], reply
    client.close()


def test_departure_is_reported_to_the_host(server, port):
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    time.sleep(0.3)
    client.close()
    seen = [m for m in host.drain(1.5) if m["t"] == "peer_left"]
    assert seen and seen[0]["player"] == "c1", seen
    host.close()


def test_a_departure_reaches_the_other_players(server, port):
    """With three players, the second client hears that the third has gone.

    Only the host was told. With two players there is nobody else to tell, so the gap was invisible: it
    took a three-player run for the second client to be found still listing a departed player as
    present, and still holding the company of somebody who had closed the game.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    one = Client(port)
    one.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    two = Client(port)
    two.send({"t": "role", "role": "client", "player": "c2", "name": "two"})
    time.sleep(0.3)
    two.close()
    time.sleep(0.2)
    host_seen = [m for m in host.drain(1.5) if m["t"] == "peer_left"]
    one_seen = [m for m in one.drain(1.5) if m["t"] == "peer_left"]
    assert host_seen and host_seen[0]["player"] == "c2", host_seen
    assert one_seen and one_seen[0]["player"] == "c2", one_seen
    # The departed player must not be told about their own departure.
    assert not [m for m in one_seen if m["player"] == "c1"], one_seen
    host.close()
    one.close()


def test_a_world_is_sent_only_to_the_player_who_asked(server, port):
    """A join must not re-send the world to players already in it.

    Every join used to fan the whole snapshot out to every client. With two players the existing one
    simply ignored the second copy; with three, the first client received the world twice and the cost
    was hundreds of parts of a multi-megabyte transfer per join.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    one = Client(port)
    one.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    two = Client(port)
    two.send({"t": "role", "role": "client", "player": "c2", "name": "two"})
    time.sleep(0.3)
    one.drain(0.5)

    host.send({"t": "world_begin", "count": 1, "for": "c2"})
    host.send({"t": "world_part", "name": "map", "i": 0, "of": 1, "data": "[]"})
    host.send({"t": "world_end"})
    time.sleep(0.5)

    got_two = [m["t"] for m in two.drain(1.0) if str(m["t"]).startswith("world")]
    got_one = [m["t"] for m in one.drain(1.0) if str(m["t"]).startswith("world")]
    assert "world_part" in got_two and "world_end" in got_two, got_two
    assert not got_one, f"the player already in the world was sent it again: {got_one}"
    host.close()
    one.close()
    two.close()


def test_a_broken_log_handle_does_not_kill_the_relay(server, port):
    """Logging must not be able to end the session.

    This is not hypothetical. tools/run-three.ps1 started the relay with stdout redirected, print()
    raised OSError(22, "Invalid argument") on the very first `role` message, and the exception left
    serve_forever() - so the relay died one message into a three-player session while all three game
    instances stayed healthy. What the players saw was a world that stopped updating for no reason.

    Tested by calling log() directly with both of its outputs broken. The first version of this case
    drove the relay over the socket instead, and passed even with the print guard removed - because the
    message-handling try/except added at the same time caught it first. A test that passes in both
    directions proves nothing, so this one targets the function under test.
    """
    class _Broken:
        def write(self, _text):
            raise OSError(22, "Invalid argument")

        def flush(self):
            raise OSError(22, "Invalid argument")

    saved_stdout = sys.stdout
    saved_file = server.log_file
    sys.stdout = _Broken()
    server.log_file = _Broken()
    try:
        server.log("a line that cannot be written anywhere")
    except OSError as exc:
        raise AssertionError(f"a failed log write killed the relay: {exc!r}") from exc
    finally:
        sys.stdout = saved_stdout
        server.log_file = saved_file


def test_a_returning_player_gets_their_company_back(server, port):
    """A player's company is kept by the relay, and handed back when they return.

    A client has no world of its own: the host owns the map and the clock, so the company a player builds
    only exists in the host's world plus the records the host publishes. If that record dies with the
    session, a returning player starts from nothing. The relay keeps the last published version of each
    company and replays it on the next join, which is what lets a *different* host serve the same player.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    time.sleep(0.2)

    # The host publishes a company for a player who is not even connected yet - that is how a player's
    # company is remembered: it is the table the host keeps.
    saved = company("c9", fanbase=4321, note=88)
    saved["offices"] = [{"t": "tile-1", "n": "Home"}]
    saved["layouts"] = [{"t": "tile-1", "items": [{"id": "22"}]}]
    saved["games"] = [{"id": "g1", "name": "A Game", "theme": "space"}]
    # The host publishes a *table* of companies, which is what the relay stores from. Waited for, not
    # slept through: how long the relay takes to have already stored it depends on the machine's load.
    host.send({"t": "companies", "companies": [saved]})
    deadline = time.time() + 5.0
    while time.time() < deadline and server.store.load("c9") is None:
        time.sleep(0.05)

    # That player now arrives.
    arriving = Client(port)
    arriving.send({"t": "role", "role": "client", "player": "c9", "name": "nine"})
    arriving.send({"t": "join_request", "player": "c9"})
    replayed = []
    deadline = time.time() + 5.0
    while time.time() < deadline and not replayed:
        message = arriving.receive(timeout=0.5)
        if message is not None and message.get("t") == "company":
            replayed.append(message)
    assert replayed, "the relay never replayed the stored company"
    record = replayed[0]["company"]
    assert record["id"] == "c9", record
    assert record["fanbase"] == 4321, record
    # The parts a player would lose are all there: their offices, the interiors of those offices, and
    # the games they made.
    assert record["offices"] == [{"t": "tile-1", "n": "Home"}], record
    assert record["layouts"] == [{"t": "tile-1", "items": [{"id": "22"}]}], record
    assert record["games"] == [{"id": "g1", "name": "A Game", "theme": "space"}], record
    arriving.close()
    host.close()


def test_a_leaving_client_keeps_its_last_company(server, port):
    """What a player did after the host's last publish survives the host dying.

    This is the disconnect case end to end: the host publishes a table, the client plays on and changes
    their company, then the host vanishes. The relay told the client the host was gone but kept the
    client's socket open for a moment, which is the window in which the client hands over its own record.
    Without that hand-over everything since the last publish - minutes of play - dies with the host.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    time.sleep(0.3)

    # The host's periodic table, from before the client did anything else. Waited for rather than slept
    # through: the two flaky cases in this suite were both asserting on state the relay had not reached.
    host.send({"t": "companies", "companies": [company("c1", fanbase=100, note=10)]})
    deadline = time.time() + 5.0
    while time.time() < deadline and server.store.load("c1") is None:
        time.sleep(0.05)

    # The client plays on. This is the part that exists nowhere else yet.
    later = company("c1", fanbase=999, note=42)
    later["offices"] = [{"t": "tile-9", "n": "Studio"}]
    later["layouts"] = [{"t": "tile-9", "items": [{"id": "5"}]}]

    # The host dies, and the relay tells the client before closing its socket.
    host.close()
    told = client.wait_for("host_left", 5.0)
    assert told is not None, "the client was never told the host had gone"

    # The client hands over what it has on the way out.
    client.send({"t": "company", "company": later})
    deadline = time.time() + 5.0
    kept = None
    while time.time() < deadline:
        kept = server.store.load("c1")
        if kept is not None and kept.get("fanbase") == 999:
            break
        time.sleep(0.05)
    client.close()

    assert kept is not None, "the player's company was lost with the host"
    assert kept["fanbase"] == 999, kept
    assert kept["offices"] == [{"t": "tile-9", "n": "Studio"}], kept
    assert kept["layouts"] == [{"t": "tile-9", "items": [{"id": "5"}]}], kept


def test_the_stored_company_survives_a_new_relay(server, port):
    """The store is on disk, so a company outlives the relay process that first saw it."""
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    time.sleep(0.2)
    host.send({"t": "companies", "companies": [company("c8", fanbase=99, note=50)]})
    time.sleep(0.4)
    host.close()
    time.sleep(0.3)

    # A completely different relay, pointed at the same directory. A returning player must still find
    # their company, which is the point of keeping it on disk rather than in memory.
    store = coop_server.CompanyStore(server.store.directory)
    loaded = store.load("c8")
    assert loaded is not None, "nothing was stored for c8"
    assert loaded["fanbase"] == 99, loaded
    assert loaded["id"] == "c8", loaded


def test_clients_are_told_when_the_host_leaves(server, port):
    """A client must be told the authority has gone, not left in a world nobody owns.

    The clock, the company table and the map all come from the host. When it disconnects the client's
    socket is still perfectly healthy - the relay is the one that noticed - so without an explicit
    message a player sits in a frozen world unable to tell "the host quit" from "the game broke".
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})
    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    time.sleep(0.4)
    host.close()
    messages = client.drain(2.0)
    told = [m for m in messages if m["t"] == "host_left"]
    assert told, messages
    client.close()


def test_slow_reader_is_not_dropped(server, port):
    """A world is megabytes and a game reads it a frame at a time.

    The relay used to sendall() on a non-blocking socket, so once a client's kernel buffer filled
    the BlockingIOError was treated as a dead connection and the client was dropped in the middle of
    the transfer. A few megabytes must queue and still arrive in full.
    """
    host = Client(port)
    host.send({"t": "role", "role": "host", "player": "h", "name": "hosty"})

    client = Client(port)
    client.send({"t": "role", "role": "client", "player": "c1", "name": "one"})
    client.send({"t": "join_request", "player": "c1"})
    time.sleep(0.3)

    parts = 24
    slice_text = "x" * 60000
    for index in range(parts):
        host.send({"t": "world_part", "name": "map", "i": index, "of": parts, "data": slice_text})
    time.sleep(1.5)                      # deliberately not reading: let the buffers fill

    received = 0
    total = 0
    while received < parts:
        message = client.receive(timeout=10.0)
        if message is None:
            break
        if message["t"] == "world_part":
            received += 1
            total += len(message["data"])

    assert received == parts, f"only {received} of {parts} parts arrived"
    assert total == parts * 60000, total
    host.close()
    client.close()


TESTS = [
    ("world reaches the joiner, also later", test_world_reaches_the_joiner),
    ("join request reaches the host", test_join_request_tells_the_host),
    ("the auto flag reaches the host", test_the_auto_flag_reaches_the_host),
    ("clock is broadcast to every client", test_clock_is_broadcast_to_every_client),
    ("client company reaches the host and is kept", test_client_company_goes_to_the_host_and_is_kept),
    ("host company table fans out", test_host_company_table_fans_out),
    ("no host is an answered error", test_no_host_means_an_answered_error),
    ("departure reported to the host", test_departure_is_reported_to_the_host),
    ("a departure reaches the other players", test_a_departure_reaches_the_other_players),
    ("a world is only sent to the player who asked", test_a_world_is_sent_only_to_the_player_who_asked),
    ("a broken log handle does not kill the relay", test_a_broken_log_handle_does_not_kill_the_relay),
    ("a returning player gets their company back", test_a_returning_player_gets_their_company_back),
    ("a leaving client keeps its last company", test_a_leaving_client_keeps_its_last_company),
    ("the stored company survives a new relay", test_the_stored_company_survives_a_new_relay),
    ("clients are told when the host leaves", test_clients_are_told_when_the_host_leaves),
    ("a slow reader still receives the whole world", test_slow_reader_is_not_dropped),
]


def main():
    failures = 0
    for index, (name, test) in enumerate(TESTS):
        # Every case gets its own company store, and the two persistence cases need one: without a
        # directory the relay deliberately remembers nothing between sessions.
        store = tempfile.mkdtemp(prefix="coop-store-")
        try:
            with_server(test, BASE_PORT + index, store)
            print(f"  ok   {name}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  FAIL {name}: {type(exc).__name__}: {exc}")
        finally:
            shutil.rmtree(store, ignore_errors=True)
    if failures:
        print(f"FAILED: {failures} problem(s)")
        return 1
    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
