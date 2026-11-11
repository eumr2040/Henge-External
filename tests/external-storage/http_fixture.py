"""Loopback-only HTTP fixture for the app's real streaming download delegate."""
import http.server
import pathlib
import socket
import sys
import time

BODY = bytes(i % 251 for i in range(1 << 20))
ETAG = '"henge-fixture-v1"'


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/missing":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        requested = self.headers.get("Range")
        start = 0
        status = 200
        if requested and self.path != "/ignore":
            if self.headers.get("If-Range") != ETAG:
                self.send_error(400, "Missing validator")
                return
            start = int(requested.removeprefix("bytes=").removesuffix("-"))
            status = 206
            if self.path == "/wrong-range":
                start += 1
        self.send_response(status)
        self.send_header("Content-Length", str(len(BODY) - start))
        self.send_header("ETag", ETAG)
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(BODY)-1}/{len(BODY)}")
        self.end_headers()
        if self.path == "/drop" and not requested:
            self.wfile.write(BODY[:65536])
            self.wfile.flush()
            # Give the client an observable body before deliberately dropping TCP.
            # An immediate close can fail before URLSession delivers response callbacks.
            time.sleep(0.2)
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
        else:
            try:
                self.wfile.write(BODY[start:])
            except (BrokenPipeError, ConnectionResetError):
                pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]), encoding="ascii")
server.serve_forever()
