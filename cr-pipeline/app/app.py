# cr-pipeline/app/app.py

import os
from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/ping")
def ping():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8090"))
    app.run(host="0.0.0.0", port=port)
