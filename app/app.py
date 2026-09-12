"""Hello World service for Tech Challenge 2."""
import os
import time
import socket

from flask import Flask, jsonify

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "1.0.0")


@app.route("/")
def hello():
    return (
        "<html><head><title>Tech Challenge 2</title></head>"
        "<body style='font-family:system-ui;text-align:center;padding-top:15vh'>"
        "<h1>Hello, World!</h1>"
        "<p>deployed by Jenkins</p>"
        f"<p>version {VERSION}</p>"
        f"<p style='color:#666'>served by pod {socket.gethostname()}</p>"
        "</body></html>"
    )


@app.route("/healthz")
def healthz():
    """Liveness + readiness probe target. Also the ALB health check path."""
    return jsonify(status="ok", version=VERSION, pod=socket.gethostname()), 200


@app.route("/load")
def load():
    """Burn CPU and hold memory for ~5s so the HPA has something to react to."""
    ballast = bytearray(20 * 1024 * 1024)  # 20MB
    deadline = time.time() + 5
    n = 0
    while time.time() < deadline:
        n += sum(i * i for i in range(1000))
    del ballast
    return jsonify(status="load complete", checksum=n), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
