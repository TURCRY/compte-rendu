import os
from datetime import datetime
from io import BytesIO

from flask import Flask, request, jsonify, send_file, Response

from .renderer import validate_payload, render_markdown, render_docx

app = Flask(__name__)


@app.get("/ping")
def ping():
    return {"status": "ok"}


@app.post("/render")
def render():
    fmt = (request.args.get("format") or "md").lower()

    try:
        data = request.get_json(force=True)
    except Exception:
        return jsonify({"error": "JSON invalide"}), 400

    ok, err = validate_payload(data)
    if not ok:
        return jsonify({"error": err}), 400

    if fmt == "md":
        md = render_markdown(data)
        return Response(md, mimetype="text/markdown")

    if fmt == "docx":
        bio: BytesIO = render_docx(data)
        name = f"compte_rendu_{datetime.utcnow().strftime('%Y-%m-%d')}.docx"
        return send_file(
            bio,
            mimetype=(
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            ),
            as_attachment=True,
            download_name=name,
        )

    return jsonify({"error": "format doit être md ou docx"}), 400


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
