#!/usr/bin/env python3
"""
Simple webhook receiver for ezthrottle-local integration tests.
Run: python3 webhook_server.py [port]
"""
from flask import Flask, request, jsonify
import json
import sys
import threading
import time

app = Flask(__name__)

received_webhooks = []
webhook_lock = threading.Lock()


@app.route('/webhook', methods=['POST'])
def webhook():
    data = request.get_json(silent=True) or {}
    entry = {
        'timestamp': time.time(),
        'headers': dict(request.headers),
        'json': data,
    }
    with webhook_lock:
        received_webhooks.append(entry)

    print(f"[WEBHOOK {len(received_webhooks)}] job_id={data.get('job_id')} status={data.get('status')}")
    print(json.dumps(data, indent=2))
    print("-" * 50)

    return jsonify({"status": "received"}), 200


@app.route('/webhooks', methods=['GET'])
def get_webhooks():
    with webhook_lock:
        return jsonify({"webhooks": received_webhooks, "count": len(received_webhooks)})


@app.route('/webhooks/latest', methods=['GET'])
def get_latest():
    with webhook_lock:
        if received_webhooks:
            return jsonify({"webhook": received_webhooks[-1], "count": len(received_webhooks)})
        return jsonify({"webhook": None, "count": 0}), 404


@app.route('/webhooks/<job_id>', methods=['GET'])
def get_by_job(job_id):
    with webhook_lock:
        matching = [w for w in received_webhooks if w.get('json', {}).get('job_id') == job_id]
        if matching:
            return jsonify({"webhook": matching[-1], "count": len(matching)})
        return jsonify({"webhook": None, "count": 0}), 404


@app.route('/reset', methods=['POST'])
def reset():
    with webhook_lock:
        received_webhooks.clear()
    print("[RESET] Cleared")
    return jsonify({"status": "reset", "count": 0})


@app.route('/health', methods=['GET'])
def health():
    with webhook_lock:
        count = len(received_webhooks)
    return jsonify({"status": "healthy", "webhook_count": count})


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
    print(f"Webhook server on http://0.0.0.0:{port}")
    app.run(host='0.0.0.0', port=port, debug=False, threaded=True)
