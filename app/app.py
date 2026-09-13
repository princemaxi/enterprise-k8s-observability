"""
Order API — demo application for the ELK capstone.

Generates realistic, structured JSON logs across INFO/WARNING/ERROR/
DEBUG/CRITICAL levels, with trace/request/correlation IDs threaded
through each request so a single order can be followed end-to-end in
Kibana. Also exposes Prometheus metrics on /metrics for kube-prometheus-
stack, and redacts sensitive fields (passwords, tokens, secrets) before
anything is logged.

Logs go to stdout only — Filebeat harvests them from the container log
file, so this app has no direct dependency on Elasticsearch or Filebeat.
"""
import json
import logging
import os
import random
import socket
import sys
import time
import uuid
from datetime import datetime, timezone

from flask import Flask, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# =====================================================
# Configuration
# =====================================================
SERVICE_NAME = os.getenv("SERVICE_NAME", "order-api")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
VERSION = os.getenv("VERSION", "1.0.0")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

app = Flask(__name__)

# =====================================================
# Prometheus metrics
# =====================================================
REQUEST_COUNT = Counter(
    "http_requests_total", "Total HTTP requests", ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram("http_request_duration_seconds", "HTTP request latency")
ORDER_CREATED = Counter("orders_created_total", "Total orders created")
LOGIN_FAILED = Counter("login_failures_total", "Failed login attempts")
PAYMENT_FAILED = Counter("payment_failures_total", "Failed payment attempts")

# =====================================================
# Structured JSON logger
# =====================================================
class JsonFormatter(logging.Formatter):
    """One JSON object per log line, matching the app-logs-template
    field mapping applied in scripts/snapshot-setup.sh."""

    SENSITIVE_FIELDS = {"password", "token", "secret", "authorization", "api_key"}

    def sanitize(self, value):
        """Recursively redact any dict key that looks sensitive, so a
        careless `extra={"business": {...}}` call can never leak a
        credential into Elasticsearch."""
        if isinstance(value, dict):
            return {
                key: "***REDACTED***" if key.lower() in self.SENSITIVE_FIELDS
                else self.sanitize(val)
                for key, val in value.items()
            }
        return value

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            "service": SERVICE_NAME,
            "environment": ENVIRONMENT,
            "version": VERSION,
            "hostname": socket.gethostname(),
            "level": record.levelname,
            "message": record.getMessage(),
            "trace_id": getattr(record, "trace_id", None),
            "request_id": getattr(record, "request_id", None),
            "correlation_id": getattr(record, "correlation_id", None),
            "user": getattr(record, "user", None),
            "client_ip": getattr(record, "client_ip", None),
            "user_agent": getattr(record, "user_agent", None),
        }
        if hasattr(record, "http"):
            payload["http"] = record.http
        if hasattr(record, "duration_ms"):
            payload["duration_ms"] = record.duration_ms
        if hasattr(record, "business"):
            payload["business"] = self.sanitize(record.business)
        if record.exc_info:
            payload["stack_trace"] = self.formatException(record.exc_info)
        return json.dumps(payload)


logger = logging.getLogger(SERVICE_NAME)
logger.setLevel(LOG_LEVEL)
stdout_handler = logging.StreamHandler(sys.stdout)
stdout_handler.setFormatter(JsonFormatter())
logger.addHandler(stdout_handler)

# =====================================================
# Demo "database"
# =====================================================
PRODUCTS = [
    {"id": 1, "name": "Terraform: Up & Running", "price": 42.99, "stock": 14},
    {"id": 2, "name": "Kubernetes in Action", "price": 39.50, "stock": 0},
    {"id": 3, "name": "Site Reliability Engineering", "price": 35.00, "stock": 27},
]
ORDERS = {}

# =====================================================
# Request correlation middleware
# =====================================================
@app.before_request
def start_request():
    g.start_time = time.time()
    # Accept IDs from an upstream ingress/API gateway if present, so a
    # trace can be followed across service boundaries; otherwise mint one.
    g.trace_id = request.headers.get("X-Trace-ID", str(uuid.uuid4()))
    g.request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    g.correlation_id = request.headers.get("X-Correlation-ID", g.trace_id)


@app.after_request
def complete_request(response):
    duration_ms = round((time.time() - g.start_time) * 1000, 2)

    REQUEST_COUNT.labels(request.method, request.path, response.status_code).inc()
    REQUEST_LATENCY.observe(duration_ms / 1000)

    logger.info(
        "request completed",
        extra={
            "trace_id": g.trace_id,
            "request_id": g.request_id,
            "correlation_id": g.correlation_id,
            "client_ip": request.remote_addr,
            "user_agent": request.headers.get("User-Agent"),
            "duration_ms": duration_ms,
            "http": {
                "method": request.method,
                "path": request.path,
                "status_code": response.status_code,
                "response_size": len(response.data),
            },
        },
    )
    return response


# =====================================================
# Health and metrics endpoints
# =====================================================
@app.route("/health")
def health():
    # Deliberately not logged at INFO — Kubernetes probes fire every few
    # seconds and would drown real events in health-check noise.
    return jsonify(status="healthy", service=SERVICE_NAME, version=VERSION), 200


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# =====================================================
# Products API
# =====================================================
@app.route("/products", methods=["GET"])
def list_products():
    logger.info(
        "listing products",
        extra={"trace_id": g.trace_id, "business": {"product_count": len(PRODUCTS)}},
    )
    return jsonify(PRODUCTS), 200


# =====================================================
# Authentication API
# =====================================================
@app.route("/login", methods=["POST"])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get("username", "unknown")

    # Simulate occasional auth failures — feeds the "Login Failures" panel
    # on the Application dashboard. Never log passwords/tokens; sensitive
    # fields are redacted automatically by JsonFormatter.sanitize.
    if not username or random.random() < 0.15:
        LOGIN_FAILED.inc()
        logger.warning(
            "login failed",
            extra={
                "trace_id": g.trace_id,
                "user": username,
                "business": {"authentication": "failed"},
            },
        )
        return jsonify(error="invalid credentials"), 401

    token = str(uuid.uuid4())
    logger.info(
        "login successful",
        extra={
            "trace_id": g.trace_id,
            "user": username,
            "business": {"authentication": "success"},
        },
    )
    return jsonify(token=token), 200


# =====================================================
# Payment API
# =====================================================
@app.route("/payment", methods=["POST"])
def payment():
    data = request.get_json(silent=True) or {}
    amount = data.get("amount", 0)
    user = data.get("user", "unknown")

    # Simulated downstream payment-gateway timeout — the kind of error
    # that should page someone, which is why it's CRITICAL not ERROR.
    if random.random() < 0.05:
        PAYMENT_FAILED.inc()
        logger.critical(
            "payment gateway timeout",
            extra={
                "trace_id": g.trace_id,
                "user": user,
                "business": {"amount": amount, "payment_status": "gateway_timeout"},
            },
        )
        return jsonify(error="payment gateway unavailable"), 503

    if amount <= 0:
        logger.error(
            "invalid payment amount",
            extra={
                "trace_id": g.trace_id,
                "user": user,
                "business": {"amount": amount, "payment_status": "rejected"},
            },
        )
        return jsonify(error="amount must be positive"), 400

    logger.info(
        "payment authorized",
        extra={
            "trace_id": g.trace_id,
            "user": user,
            "business": {"amount": amount, "payment_status": "success"},
        },
    )
    return jsonify(status="authorized", amount=amount), 200


# =====================================================
# Checkout API
# =====================================================
@app.route("/checkout", methods=["POST"])
def checkout():
    data = request.get_json(silent=True) or {}
    product_id = data.get("product_id")
    user = data.get("user", "unknown")
    product = next((p for p in PRODUCTS if p["id"] == product_id), None)

    if not product:
        logger.error(
            "checkout product not found",
            extra={
                "trace_id": g.trace_id,
                "user": user,
                "business": {"product_id": product_id, "checkout_status": "failed"},
            },
        )
        return jsonify(error="product not found"), 404

    if product["stock"] <= 0:
        logger.warning(
            "checkout failed out of stock",
            extra={
                "trace_id": g.trace_id,
                "user": user,
                "business": {"product_id": product_id, "checkout_status": "out_of_stock"},
            },
        )
        return jsonify(error="out of stock"), 409

    logger.info(
        "checkout completed",
        extra={
            "trace_id": g.trace_id,
            "user": user,
            "business": {
                "product_id": product_id,
                "subtotal": product["price"],
                "checkout_status": "success",
            },
        },
    )
    return jsonify(product=product, subtotal=product["price"]), 200


# =====================================================
# Orders API
# =====================================================
@app.route("/orders", methods=["POST"])
def create_order():
    data = request.get_json(silent=True) or {}
    order_id = str(uuid.uuid4())
    user = data.get("user", "unknown")

    try:
        # Simulate an occasional unhandled exception to exercise the
        # stack-trace field and the ERROR + exc_info path.
        if random.random() < 0.03:
            raise RuntimeError("order database write conflict")

        ORDERS[order_id] = data
        ORDER_CREATED.inc()
        logger.info(
            "order created",
            extra={
                "trace_id": g.trace_id,
                "user": user,
                "business": {"order_id": order_id, "order_status": "created"},
            },
        )
        return jsonify(order_id=order_id, status="created"), 201

    except RuntimeError:
        logger.error(
            "order creation failed",
            exc_info=True,
            extra={
                "trace_id": g.trace_id,
                "user": user,
                "business": {"order_id": order_id, "order_status": "failed"},
            },
        )
        return jsonify(error="internal server error"), 500


# =====================================================
# Global exception handler
# =====================================================
@app.errorhandler(Exception)
def handle_exception(error):
    logger.exception(
        "unhandled application exception",
        extra={
            "trace_id": getattr(g, "trace_id", None),
            "business": {"exception": str(error)},
        },
    )
    return jsonify(error="unexpected error"), 500


# =====================================================
# Startup
# =====================================================
if __name__ == "__main__":
    logger.info(
        "application starting",
        extra={
            "business": {
                "service": SERVICE_NAME,
                "environment": ENVIRONMENT,
                "version": VERSION,
            }
        },
    )
    app.run(host="0.0.0.0", port=8080)
