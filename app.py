import logging
import os
from datetime import datetime, timezone
from urllib.parse import quote

from flask import Flask, jsonify, request
from pymongo import MongoClient
from pymongo.errors import PyMongoError

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

_client = None


def configure_mongodb_uri():
    """Build MONGODB_URI from discrete env vars when not supplied directly."""
    if os.environ.get("MONGODB_URI"):
        return

    username = os.environ.get("MONGO_USERNAME")
    password = os.environ.get("MONGO_PASSWORD")
    if not username or not password:
        return

    host = os.environ.get("MONGO_HOST", "mongo-service")
    port = os.environ.get("MONGO_PORT", "27017")
    database = os.environ.get("MONGO_DATABASE", "flaskdb")
    auth_source = os.environ.get("MONGO_AUTH_SOURCE", "admin")

    os.environ["MONGODB_URI"] = (
        f"mongodb://{quote(username, safe='')}:{quote(password, safe='')}"
        f"@{host}:{port}/{database}?authSource={auth_source}"
    )


def get_client():
    global _client

    configure_mongodb_uri()
    uri = os.environ.get("MONGODB_URI")
    if not uri:
        raise RuntimeError("MONGODB_URI environment variable is not set")

    if _client is None:
        _client = MongoClient(
            uri,
            serverSelectionTimeoutMS=5000,
            connectTimeoutMS=5000,
            retryWrites=True,
        )

    return _client


def reset_client():
    global _client
    if _client is not None:
        _client.close()
        _client = None


def get_collection():
    client = get_client()
    db_name = os.environ.get("MONGODB_DATABASE", "flaskdb")
    return client[db_name]["records"]


def ping_mongodb():
    get_client().admin.command("ping")


configure_mongodb_uri()


@app.route("/")
def index():
    current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"Welcome to the Flask app! The current time is: {current_time}"


@app.route("/data", methods=["POST"])
def insert_data():
    payload = request.get_json(silent=True)
    if payload is None:
        return jsonify({"error": "Request body must be valid JSON"}), 400

    document = {
        "data": payload,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    try:
        result = get_collection().insert_one(document)
        return (
            jsonify({"message": "Data inserted successfully", "id": str(result.inserted_id)}),
            201,
        )
    except PyMongoError:
        logger.exception("Failed to insert data into MongoDB")
        reset_client()
        return jsonify({"error": "Failed to insert data"}), 500


@app.route("/data", methods=["GET"])
def get_data():
    try:
        records = []
        for document in get_collection().find():
            document["_id"] = str(document["_id"])
            records.append(document)
        return jsonify({"count": len(records), "records": records}), 200
    except PyMongoError:
        logger.exception("Failed to retrieve data from MongoDB")
        reset_client()
        return jsonify({"error": "Failed to retrieve data"}), 500


@app.route("/health")
def health():
    """Lightweight liveness endpoint — does not depend on MongoDB."""
    return jsonify({"status": "ok"}), 200


@app.route("/ready")
def ready():
    """Readiness endpoint — verifies MongoDB connectivity."""
    try:
        ping_mongodb()
        return jsonify({"status": "ready"}), 200
    except PyMongoError:
        logger.exception("MongoDB readiness check failed")
        reset_client()
        return jsonify({"status": "not ready"}), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
