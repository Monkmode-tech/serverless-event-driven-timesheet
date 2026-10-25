"""Shared helpers: AWS clients (lazy), HTTP responses, caller identity, metrics, logging."""

from __future__ import annotations

import json
import logging
import os
import time
from decimal import Decimal
from typing import Any

LOG = logging.getLogger("timesheet")
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

EMPLOYEES = "employees"
MANAGERS = "managers"
HR = "hr"

_clients: dict[str, Any] = {}


def client(name: str) -> Any:
    """boto3 client, created once per container. Imported lazily so unit tests need no AWS SDK."""
    if name not in _clients:
        import boto3

        _clients[name] = boto3.client(name)
    return _clients[name]


def table() -> Any:
    if "table" not in _clients:
        import boto3

        _clients["table"] = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _clients["table"]


def to_json(value: Any) -> str:
    def default(o: Any) -> Any:
        if isinstance(o, Decimal):
            return int(o) if o == o.to_integral_value() else float(o)
        if isinstance(o, set):
            return sorted(o)
        raise TypeError(type(o).__name__)

    return json.dumps(value, default=default, separators=(",", ":"))


def response(status: int, body: Any) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": to_json(body),
    }


def error(status: int, message: str) -> dict[str, Any]:
    return response(status, {"error": message})


class Caller:
    """Identity from the API Gateway JWT authorizer (a Cognito access token)."""

    def __init__(self, claims: dict[str, Any]):
        self.user_id: str = claims.get("sub", "")
        self.username: str = claims.get("username", "")
        groups = claims.get("cognito:groups", "")
        # HTTP API passes list claims as "[a b]" strings.
        if isinstance(groups, str):
            groups = groups.strip("[]").replace(",", " ").split()
        self.groups: set[str] = set(groups)

    def is_(self, group: str) -> bool:
        return group in self.groups

    @classmethod
    def from_event(cls, event: dict[str, Any]) -> Caller:
        claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
        return cls(claims)


def log(level: int, msg: str, **fields: Any) -> None:
    """Structured JSON logs. Never pass names, rates or note text - IDs only."""
    LOG.log(level, to_json({"msg": msg, **fields}))


def metric(name: str, value: float, unit: str = "Count", **dimensions: str) -> None:
    """CloudWatch Embedded Metric Format: a log line that CloudWatch turns into a metric (no API call)."""
    namespace = os.environ.get("METRICS_NAMESPACE", "Timesheet")
    dims = {"Service": os.environ.get("SERVICE_NAME", "timesheet"), **dimensions}
    print(
        to_json(
            {
                "_aws": {
                    "Timestamp": int(time.time() * 1000),
                    "CloudWatchMetrics": [
                        {"Namespace": namespace, "Dimensions": [list(dims)], "Metrics": [{"Name": name, "Unit": unit}]}
                    ],
                },
                name: value,
                **dims,
            }
        )
    )
