"""Tiny Flask app used to demonstrate the CI/CD pipeline."""
from flask import Flask, jsonify

app = Flask(__name__)


def add(a: int, b: int) -> int:
    return a + b


@app.route("/")
def index():
    return jsonify(message="Hello from the Jenkins CI/CD pipeline!", status="ok")


@app.route("/health")
def health():
    return jsonify(status="healthy")


@app.route("/add/<int:a>/<int:b>")
def add_route(a, b):
    return jsonify(result=add(a, b))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
