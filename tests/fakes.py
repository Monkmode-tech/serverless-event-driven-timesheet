"""In-memory stand-ins for the AWS SDK objects the code uses.

FakeTable evaluates the real condition / key-condition / update expressions the
code sends (the subset of the DynamoDB grammar this project uses), so tests
exercise optimistic concurrency and lifecycle rules for real.
"""

from __future__ import annotations

import copy
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))


class FakeClientError(Exception):
    def __init__(self, code: str, reasons: list | None = None):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}
        if reasons is not None:
            self.response["CancellationReasons"] = reasons


def _resolve(token: str, names: dict, values: dict):
    if token.startswith(":"):
        return ("value", values[token])
    return ("attr", names.get(token, token))


class _Cond:
    """Tiny recursive-descent evaluator: comparisons, attribute_(not_)exists, AND, OR, parentheses."""

    TOKEN = re.compile(r"\(|\)|AND|OR|attribute_not_exists\(\w+\)|attribute_exists\(\w+\)|[#:\w]+\s*(?:=|<>)\s*[#:\w]+")

    def __init__(self, expr: str, item: dict | None, names: dict, values: dict):
        self.tokens = self.TOKEN.findall(expr)
        self.i = 0
        self.item = item or {}
        self.names, self.values = names, values

    def parse(self) -> bool:
        result = self._or()
        assert self.i == len(self.tokens), f"unparsed condition: {self.tokens[self.i:]}"
        return result

    def _or(self) -> bool:
        left = self._and()
        while self.i < len(self.tokens) and self.tokens[self.i] == "OR":
            self.i += 1
            right = self._and()
            left = left or right
        return left

    def _and(self) -> bool:
        left = self._atom()
        while self.i < len(self.tokens) and self.tokens[self.i] == "AND":
            self.i += 1
            right = self._atom()
            left = left and right
        return left

    def _atom(self) -> bool:
        tok = self.tokens[self.i]
        self.i += 1
        if tok == "(":
            value = self._or()
            self.i += 1  # ")"
            return value
        m = re.match(r"attribute_(not_)?exists\((\w+)\)", tok)
        if m:
            exists = m.group(2) in self.item
            return not exists if m.group(1) else exists
        left, op, right = re.match(r"([#:\w]+)\s*(=|<>)\s*([#:\w]+)", tok).groups()
        lv, rv = (self._val(left), self._val(right))
        return lv == rv if op == "=" else lv != rv

    def _val(self, token: str):
        kind, v = _resolve(token, self.names, self.values)
        return v if kind == "value" else self.item.get(v)


class FakeTable:
    def __init__(self, items: list[dict] | None = None):
        self.items: dict[tuple[str, str], dict] = {}
        for item in items or []:
            self.items[(item["PK"], item["SK"])] = copy.deepcopy(item)
        self.calls: list[tuple[str, dict]] = []

    @staticmethod
    def _key(key: dict) -> tuple[str, str]:
        return (key["PK"], key["SK"])

    def _check(self, kwargs: dict, existing: dict | None) -> None:
        expr = kwargs.get("ConditionExpression")
        if expr and not _Cond(
            expr, existing, kwargs.get("ExpressionAttributeNames", {}), kwargs.get("ExpressionAttributeValues", {})
        ).parse():
            raise FakeClientError("ConditionalCheckFailedException")

    def get_item(self, Key: dict, ConsistentRead: bool = False) -> dict:
        self.calls.append(("get_item", Key))
        item = self.items.get(self._key(Key))
        return {"Item": copy.deepcopy(item)} if item else {}

    def put_item(self, Item: dict, **kwargs) -> dict:
        self.calls.append(("put_item", Item))
        self._check(kwargs, self.items.get(self._key(Item)))
        self.items[self._key(Item)] = copy.deepcopy(Item)
        return {}

    def update_item(self, Key: dict, UpdateExpression: str, **kwargs) -> dict:
        self.calls.append(("update_item", Key))
        existing = self.items.get(self._key(Key))
        self._check(kwargs, existing)
        item = copy.deepcopy(existing) if existing else dict(Key)
        names, values = kwargs.get("ExpressionAttributeNames", {}), kwargs.get("ExpressionAttributeValues", {})
        assert UpdateExpression.startswith("SET "), "fake supports SET only"
        for part in UpdateExpression[4:].split(","):
            attr, val = (x.strip() for x in part.split("="))
            item[names.get(attr, attr)] = values[val]
        self.items[self._key(Key)] = item
        return {}

    def query(self, KeyConditionExpression: str, ExpressionAttributeValues: dict, IndexName: str | None = None,
              ScanIndexForward: bool = True, Limit: int | None = None, ExclusiveStartKey: dict | None = None) -> dict:
        self.calls.append(("query", {"index": IndexName, "expr": KeyConditionExpression}))
        first, rest = KeyConditionExpression.split(" AND ", 1) if " AND " in KeyConditionExpression else (
            KeyConditionExpression, None)
        pk_attr, pk_val = re.match(r"(\w+) = (:\w+)", first).groups()
        rows = [i for i in self.items.values() if i.get(pk_attr) == ExpressionAttributeValues[pk_val]]
        sk_attr = None
        if rest:
            m = re.match(r"begins_with\((\w+), (:\w+)\)", rest)
            if m:
                sk_attr, prefix = m.group(1), ExpressionAttributeValues[m.group(2)]
                rows = [i for i in rows if str(i.get(sk_attr, "")).startswith(prefix)]
            else:
                sk_attr, lo, hi = re.match(r"(\w+) BETWEEN (:\w+) AND (:\w+)", rest).groups()
                lo, hi = ExpressionAttributeValues[lo], ExpressionAttributeValues[hi]
                rows = [i for i in rows if lo <= str(i.get(sk_attr, "")) <= hi]
        sort_attr = sk_attr or ("SK" if IndexName is None else f"{IndexName}SK")
        rows.sort(key=lambda i: str(i.get(sort_attr, "")), reverse=not ScanIndexForward)
        if Limit:
            rows = rows[:Limit]
        return {"Items": copy.deepcopy(rows)}


class FakeSFN:
    def __init__(self):
        self.started: set[str] = set()
        self.calls: list[dict] = []

    def start_execution(self, stateMachineArn: str, name: str, input: str) -> dict:
        if name in self.started:
            raise FakeClientError("ExecutionAlreadyExists")
        self.started.add(name)
        self.calls.append({"name": name, "input": input})
        return {"executionArn": f"{stateMachineArn}:{name}"}


class FakeS3:
    def __init__(self):
        self.objects: dict[str, dict] = {}

    def put_object(self, Bucket: str, Key: str, Body: bytes, **kwargs) -> dict:
        self.objects[Key] = {"Body": Body, **kwargs}
        return {}

    def generate_presigned_url(self, op: str, Params: dict, ExpiresIn: int) -> str:
        return f"https://{Params['Bucket']}.s3.amazonaws.com/{Params['Key']}?X-Amz-Expires={ExpiresIn}"


class FakeSNS:
    def __init__(self):
        self.published: list[dict] = []

    def publish(self, **kwargs) -> dict:
        self.published.append(kwargs)
        return {"MessageId": str(len(self.published))}


class FakeDynamoDBClient:
    """transact_write_items with the one condition the ledger uses (marker must not exist)."""

    def __init__(self):
        self.markers: set[tuple[str, str]] = set()
        self.totals: dict[tuple[str, str], int] = {}

    def transact_write_items(self, TransactItems: list[dict]) -> dict:
        put = TransactItems[0]["Put"]["Item"]
        marker = (put["PK"]["S"], put["SK"]["S"])
        if marker in self.markers:
            raise FakeClientError("TransactionCanceledException", [{"Code": "ConditionalCheckFailed"}])
        self.markers.add(marker)
        for t in TransactItems[1:]:
            u = t["Update"]
            key = (u["Key"]["PK"]["S"], u["Key"]["SK"]["S"])
            self.totals[key] = self.totals.get(key, 0) + int(u["ExpressionAttributeValues"][":qh"]["N"])
        return {}
