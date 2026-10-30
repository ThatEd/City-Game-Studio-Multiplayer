#!/usr/bin/env python3
"""Co-op relay server for City Game Studio.

Why a separate process: the game's engine build cannot accept a TCP connection (TCPServer is
stripped; only StreamPeerTCP, an outbound client, survives). Every game instance therefore dials
out to this process and it moves messages between them. That also keeps the game side free of
delivery concerns, which is what makes this stable.

Roles, and why the host matters:

    host    the player whose game owns the world. Its save defines the starting state: year,
            market, existing companies. It also owns time (pause and speed).
    client  a player joining that world: receives the world once, picks a company, then only
            exchanges company records.

Routing:

    client -> host    everything: join requests, the client's company record
    host   -> clients everything: world snapshot, clock, the company table
    A client never sees another client's raw traffic.

The relay does not interpret game data, so a new message type needs no server change.

Wire format: 8 decimal digits of byte length, then that many bytes of JSON.

    python coop_server.py --port 7480
    python coop_server.py --port 7480 --log coop-server.log
"""
import argparse
import json
import os
import selectors
import socket
import sys
import time
import traceback

PREFIX = 8
MAX_MESSAGE = 64 * 1024 * 1024

# How long a client's socket stays open after it is told the host has gone.
#
# Long enough for the client to save and hand its own company over, short enough that a client which
# ignores the message does not linger. The client is expected to close its own socket and usually does.
HOST_LEFT_GRACE = 20.0


def now():
    return time.strftime("%H:%M:%S")


class CompanyStore:
    """What the relay remembers about a player between sessions.

    A client has no world of its own and no authority over one: the host owns the map and the clock. So
    when a player's own game saves on disconnect, the record that matters is not their local save file -
    it is the company record the host was being told about. The relay is the one place both sides reach,
    so it is where that record is kept, and a fresh host can be handed it again when the player returns.

    Only the company travels: identity, money, fanbase, offices and the interiors of those offices, the
    games it has made, its consoles and its conventions. The world itself - the map, the rivals, the date -
    belongs to whoever is hosting and is never stored here.
    """

    KEPT = (
        "id", "name", "note", "fanbase", "currency", "studios", "offices", "layouts",
        "consoles", "games", "genres", "conventions", "save", "session",
    )

    def __init__(self, directory=None):
        self.directory = directory
        if directory:
            os.makedirs(directory, exist_ok=True)

    def path_for(self, player_id):
        safe = "".join(c for c in str(player_id) if c.isalnum() or c in "-_")[:64]
        return os.path.join(self.directory, f"{safe}.json") if safe else None

    def keep(self, record):
        """Stores one company record. Called with every record the host publishes."""
        if not self.directory or not isinstance(record, dict):
            return False
        player_id = record.get("id")
        if not player_id:
            return False
        path = self.path_for(player_id)
        if not path:
            return False
        kept = {key: record[key] for key in self.KEPT if key in record}
        kept["saved_at"] = int(time.time())
        tmp = path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as handle:
                json.dump(kept, handle, ensure_ascii=True)
            os.replace(tmp, path)
        except OSError:
            return False
        return True

    def load(self, player_id):
        """The stored record for a player, or None."""
        if not self.directory or not player_id:
            return None
        path = self.path_for(player_id)
        if not path or not os.path.exists(path):
            return None
        try:
            with open(path, "r", encoding="utf-8") as handle:
                record = json.load(handle)
        except (OSError, ValueError):
            return None
        return record if isinstance(record, dict) else None


class Client:
    def __init__(self, sock, address):
        self.sock = sock
        self.address = address
        self.buffer = b""
        self.role = None            # "host" | "client"
        self.player_id = None
        self.name = ""
        self.world = None           # last world snapshot sent by the host
        self.clock = None           # last clock message sent by the host
        self.out = bytearray()      # bytes accepted but not yet written to the socket
        self.expires_at = None      # monotonic time at which this socket is closed regardless

    def label(self):
        if self.player_id:
            return f"{self.role or '?'}:{self.player_id}({self.name})"
        return f"{self.role or '?'}:{self.address[0]}:{self.address[1]}"


class Server:
    def __init__(self, port, log_path=None, host="0.0.0.0", store_dir=None):
        self.port = port
        self.host = host
        self.selector = selectors.DefaultSelector()
        self.clients = {}
        self.running = False
        # Appended, not truncated: a relay restarted to resume a session must keep the earlier half of
        # the run. Callers that want a fresh file (the test runner) delete it first.
        self.log_file = open(log_path, "a", encoding="utf-8") if log_path else None
        self.stats_forwarded = 0
        self.stats_bytes = 0
        self.store = CompanyStore(store_dir)
        self.stats_saved = 0
        # The player a world transfer in progress is addressed to, or None for "everyone". See
        # forward_to_clients: a joining player needs the world, a player already in it does not.
        self.world_target = None

    def log(self, text):
        line = f"[{now()}] {text}"
        # Neither output may kill the relay.
        #
        # This is not defensive noise: it happened. A relay started with its stdout redirected - which
        # is exactly how tools/run-three.ps1 started it - raised OSError(22, "Invalid argument") from
        # print() on the very first `role` message, and the exception went all the way out of
        # serve_forever(). The relay died one message into the session while every game instance stayed
        # perfectly healthy, so the symptom was three players sitting in a world that mysteriously
        # stopped updating. A log line is the least important thing the server does; it must be the
        # thing that is allowed to fail.
        try:
            print(line, flush=True)
        except (OSError, ValueError):
            pass
        if self.log_file:
            try:
                self.log_file.write(line + "\n")
                self.log_file.flush()
            except (OSError, ValueError):
                pass

    # --- lifecycle ------------------------------------------------------

    def start(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((self.host, self.port))
        listener.listen(16)
        listener.setblocking(False)
        self.selector.register(listener, selectors.EVENT_READ, None)
        self.listener = listener
        self.log(f"listening on {self.host}:{self.port}")

    def serve_forever(self):
        self.start()
        self.running = True
        while self.running:
            try:
                events = self.selector.select(timeout=1.0)
            except OSError:
                break
            self.reap_expired()
            for key, _events in events:
                if key.data is None:
                    try:
                        self.accept(key.fileobj)
                    except OSError:
                        pass
                    continue

                client = key.data
                # Both halves are guarded by "is this client still registered": a read can drop the
                # client, and the same select() result can still list it.
                if _events & selectors.EVENT_READ and self.clients.get(client.sock) is client:
                    self.read(client)
                if self.clients.get(client.sock) is client and _events & selectors.EVENT_WRITE:
                    self.flush(client)

    def stop(self):
        self.running = False
        for client in list(self.clients.values()):
            try:
                client.sock.close()
            except OSError:
                pass
        self.clients = {}
        for closer in (getattr(self, "listener", None), self.selector):
            try:
                closer.close()
            except (OSError, AttributeError):
                pass

    def reap_expired(self):
        """Closes sockets that were kept open only to let a client answer first."""
        moment = time.monotonic()
        for client in list(self.clients.values()):
            if client.expires_at is not None and moment >= client.expires_at:
                self.log(f"{client.label()} did not close its own socket, closing it here")
                self.drop(client)

    def accept(self, listener):
        sock, address = listener.accept()
        sock.setblocking(False)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client = Client(sock, address)
        self.clients[sock] = client
        self.selector.register(sock, selectors.EVENT_READ, client)
        self.log(f"connected {client.label()}")

    def drop(self, client, reason=""):
        # Idempotent. The event loop iterates the result of one select() call and can reach the same
        # client twice, and a socket that has been closed but not unregistered stays readable forever -
        # so a second drop() logged "disconnected" again and, worse, recv() on the closed socket kept
        # raising and kept being reported. One drop per client, and it must be the one that removes it.
        if client.sock not in self.clients:
            return
        self.log(f"disconnected {client.label()}" + (f" [{reason}]" if reason else ""))
        try:
            self.selector.unregister(client.sock)
        except (KeyError, ValueError):
            pass
        try:
            client.sock.close()
        except OSError:
            pass
        self.clients.pop(client.sock, None)

        was_host = client.role == "host"
        host = self.host_client()
        if was_host:
            # The host is gone. Every client is now playing a world nobody owns: the clock, the company
            # table and the map all came from that one machine. Tell them, and leave their sockets open
            # for a moment rather than closing them here.
            #
            # The client answers a "host_left" by saving its company and handing that record back. Closing
            # the socket in this same call left no window to do it in, so everything the player had done
            # since the host's last company table - minutes of play, the exact part worth keeping - was
            # dropped on the floor. The client closes its own socket after handing over; the grace below
            # is only there in case it never does.
            for remaining in self.client_list():
                self.send(remaining, {"t": "host_left", "message": "the host left the session"})
                self.log(f"told {remaining.label()} the host is gone")
                remaining.expires_at = time.monotonic() + HOST_LEFT_GRACE
            return
        if client is not host and host is not None and client.player_id:
            self.send(host, {"t": "peer_left", "player": client.player_id})
            # Every *other* player is told too, not only the host. With two players there is nobody
            # else to tell, which is why this went unnoticed: with three, the second client kept
            # listing the departed player as present for the rest of the run, and its rival list kept a
            # company that no longer had anybody behind it. The host answers a peer_left by pausing and
            # asking whether to carry on; a client answers it by noticing somebody is gone.
            for remaining in self.client_list():
                if remaining is client or remaining.player_id == client.player_id:
                    continue
                self.send(remaining, {"t": "peer_left", "player": client.player_id})
                self.log(f"told {remaining.label()} that {client.player_id} left")

    # --- helpers --------------------------------------------------------

    def host_client(self):
        for client in self.clients.values():
            if client.role == "host":
                return client
        return None

    def client_list(self):
        return [c for c in self.clients.values() if c.role == "client"]

    # --- messages -------------------------------------------------------

    def read(self, client):
        try:
            chunk = client.sock.recv(1 << 20)
        except BlockingIOError:
            # Woken for a write, or a spurious readable event: nothing to take.
            return
        except OSError as exc:
            # The reason matters. In a three-player run a client was dropped here with the log saying
            # only "disconnected", and the client itself never noticed: it kept sending, with its socket
            # in a state its own StreamPeerTCP never reported as closed, for the rest of the run. The
            # players' evidence is not enough to tell a reset from a broken pipe from a timeout, and the
            # three are fixed in different places, so the errno and its message are recorded.
            self.log(f"read failed on {client.label()}: {exc!r} (errno {exc.errno})")
            self.drop(client)
            return
        except Exception as exc:  # noqa: BLE001
            self.log(f"read raised on {client.label()}: {exc!r}")
            self.drop(client)
            return

        if not chunk:
            # A clean FIN: the peer closed its side. Distinguished from the errors above on purpose.
            self.log(f"{client.label()} closed its side of the connection")
            self.drop(client)
            return

        client.buffer += chunk
        while True:
            if len(client.buffer) < PREFIX:
                return
            prefix = client.buffer[:PREFIX]
            if not prefix.isdigit():
                self.log(f"bad frame prefix from {client.label()}: {prefix!r}")
                self.drop(client)
                return
            length = int(prefix)
            if length <= 0 or length > MAX_MESSAGE:
                self.log(f"bad frame length {length} from {client.label()}")
                self.drop(client)
                return
            if len(client.buffer) < PREFIX + length:
                return

            body = client.buffer[PREFIX:PREFIX + length]
            client.buffer = client.buffer[PREFIX + length:]
            try:
                message = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                self.log(f"bad JSON from {client.label()}: {exc}")
                continue
            # Last line of defence for the whole session. One malformed or unexpected message from one
            # client must not end the relay for everybody: an uncaught exception here propagates out of
            # serve_forever() and stops the fan-out for every player at once, while all the game
            # instances stay healthy and simply stop hearing from each other.
            try:
                self.handle(client, message, len(body))
            except Exception as exc:  # noqa: BLE001
                self.log(f"handling {message.get('t')!r} from {client.label()} failed: {exc!r}")
                self.log(traceback.format_exc().replace("\n", " | "))

    def handle(self, client, message, size):
        kind = message.get("t")

        if kind == "role":
            client.role = "host" if message.get("role") == "host" else "client"
            client.player_id = str(message.get("player", ""))[:64]
            client.name = str(message.get("name", ""))[:64]
            self.log(f"role {client.label()}")
            return

        if kind == "ping":
            # Cheap round trip. The game's transport is only proven to read on sockets that have
            # not been written to yet, so this exercises read-after-write in isolation.
            self.send(client, {"t": "pong", "echo": message.get("echo", "")})
            return

        if kind == "join_request":
            host = self.host_client()
            if host is None:
                self.send(client, {"t": "error", "message": "no host is running"})
                return
            self.log(f"join request from {client.label()}")
            # A returning player: give them back the company the relay remembers for them, before the
            # host starts publishing its own table. The host treats a "company" message as authoritative,
            # so the stored copy is what this player's company will be built from.
            stored = self.store.load(client.player_id)
            if stored is not None:
                self.log(f"replaying the stored company for {client.player_id}")
                self.send(client, {"t": "company", "company": stored})
            self.send(host, {
                "t": "join_request",
                "player": client.player_id,
                "name": client.name,
                # Forwarded, not invented: the client decides whether it can show a lobby, and the host
                # acts on that answer. Dropping it here made every automated join look like an
                # interactive one, so the host offered a lobby nobody could press and the client sat in
                # the main menu while the host's clock ran on.
                "auto": bool(message.get("auto", False)),
            })
            if host.world is not None:
                self.log("replaying the cached world to the joiner")
                self.send(client, host.world)
            return

        if client.role == "host":
            # A world transfer is addressed to the player who just chose their company. `world_begin`
            # carries the address, `world_part`/`world_end` do not, so the relay remembers it for the
            # duration of the transfer rather than putting a tag on every one of hundreds of parts.
            # A host that sends no address (an older mod) keeps the old fan-out behaviour.
            only = None
            if kind == "world_begin":
                only = str(message.get("for", "")) or None
                self.world_target = only
            elif kind in ("world_part", "world_end"):
                only = self.world_target
            self.forward_to_clients(message, size, only)
            if kind == "world":
                client.world = message
            elif kind == "world_end":
                self.world_target = None
            elif kind == "companies":
                # The host publishes the whole company table every few seconds, so this is where each
                # player's company is kept current while they are connected. Storing from the table (not
                # from a single "company" message) is what makes a returning player's company available
                # to a *new* host, not only to the one they were playing with.
                table = message.get("companies")
                if isinstance(table, list):
                    for record in table:
                        if isinstance(record, dict) and self.store.keep(record):
                            self.stats_saved += 1
            elif kind == "company":
                record = message.get("company")
                if isinstance(record, dict) and self.store.keep(record):
                    self.stats_saved += 1
            return

        # A client only ever talks to the host, with one exception: its own saved company. The relay keeps
        # that copy for the moment the host vanishes between publishes. Everything since the host's last
        # table would otherwise be lost - which is exactly the part worth keeping. The message still goes
        # to the host as usual, so the world stays consistent while both are alive.
        if kind == "company":
            record = message.get("company")
            if isinstance(record, dict) and self.store.keep(record):
                self.stats_saved += 1

        host = self.host_client()
        if host is not None:
            self.send(host, message)

    def forward_to_clients(self, message, size, only=None):
        for client in self.client_list():
            # A world snapshot can be addressed to one player. Without this, every join re-sent the whole
            # world - megabytes, split into hundreds of parts - to *every* client already playing, and
            # their `__on_world` ignored it. Invisible with two players, expensive and confusing with
            # three, and the third player's lobby summary listed a world it had to throw away.
            if only is not None and client.player_id != only:
                continue
            self.send(client, message)
        self.stats_forwarded += 1
        self.stats_bytes += size

    def send(self, client, message):
        # A dropped client can still be named by a loop that built its list from an earlier moment (the
        # host-left fan-out, the company table, the world replay). Writing to it produced a cascade of
        # "write failed" lines for every later message, which buries the one line that says why the
        # connection actually ended.
        if client.sock not in self.clients:
            return
        # ensure_ascii is explicit: the game reads frames as a String and uses the byte length from
        # the prefix as a character offset, which is only correct while everything on the wire is
        # ASCII. json.dumps escapes anything else by default; keep it that way.
        body = json.dumps(message, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        client.out += f"{len(body):0{PREFIX}d}".encode("ascii") + body
        self.flush(client)

    def flush(self, client):
        if client.sock not in self.clients:
            return
        if client.out:
            try:
                sent = client.sock.send(client.out)
            except BlockingIOError:
                sent = 0
            except OSError as exc:
                self.log(f"write failed to {client.label()}: {exc!r} (errno {exc.errno})")
                self.drop(client, "write failed")
                return
            if sent:
                del client.out[:sent]
        self.set_interest(client)

    # A world snapshot is megabytes and a joining game reads it no faster than its frame loop, so a
    # write that cannot complete is queued and retried instead of ending the connection.
    def set_interest(self, client):
        events = selectors.EVENT_READ
        if client.out:
            events |= selectors.EVENT_WRITE
        try:
            self.selector.modify(client.sock, events, client)
        except (KeyError, ValueError):
            pass


def main(argv=None):
    parser = argparse.ArgumentParser(description="City Game Studio co-op relay server")
    parser.add_argument("--port", type=int, default=7480)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--log", default=None, help="also append the log to this file")
    parser.add_argument(
        "--stores",
        default=None,
        help="directory to keep player companies in, so a returning player is handed theirs back. "
             "Without it the relay forgets every company when the session ends.",
    )
    args = parser.parse_args(argv)

    server = Server(args.port, args.log, args.host, args.stores)
    if args.stores:
        server.log(f"keeping player companies in {args.stores}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
