#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sqlite3
from collections import deque
from pathlib import Path


def default_db(workspace: Path) -> Path:
    return workspace / "memory" / "graph" / "graph.sqlite"


def connect(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise SystemExit(f"graph database not found: {db_path}")
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def print_json(value: object) -> None:
    print(json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True))


def load_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            rows.append(value)
    return rows


def cosine(left: list[float], right: list[float]) -> float:
    return sum(a * b for a, b in zip(left, right))


def stats(conn: sqlite3.Connection) -> dict:
    entity_count = conn.execute("select count(*) from entities").fetchone()[0]
    edge_count = conn.execute("select count(*) from edges").fetchone()[0]
    top_entities = [
        dict(row)
        for row in conn.execute(
            "select id, name, mentions, degree, confidence from entities order by degree desc, mentions desc limit 12"
        )
    ]
    top_edges = [
        dict(row)
        for row in conn.execute(
            "select source_name, target_name, relation, polarity, extraction, count, confidence, source_path, start_line, end_line from edges order by count desc, confidence desc limit 12"
        )
    ]
    return {"entityCount": entity_count, "edgeCount": edge_count, "topEntities": top_entities, "topEdges": top_edges}


def find_entities(conn: sqlite3.Connection, query: str) -> list[sqlite3.Row]:
    like = f"%{query}%"
    return list(
        conn.execute(
            "select * from entities where name like ? or id = ? order by degree desc, mentions desc limit 20",
            (like, query),
        )
    )


def connections(conn: sqlite3.Connection, query: str, limit: int) -> dict:
    matches = find_entities(conn, query)
    if not matches:
        return {"query": query, "matches": [], "connections": []}
    entity = matches[0]
    rows = [
        dict(row)
        for row in conn.execute(
            """
            select e.*, other.name as neighbor_name
            from edges e
            join entities other on other.id = case when e.source = ? then e.target else e.source end
            where e.source = ? or e.target = ?
            order by e.count desc, e.confidence desc
            limit ?
            """,
            (entity["id"], entity["id"], entity["id"], limit),
        )
    ]
    return {"query": query, "match": dict(entity), "connections": rows}


def shortest_path(conn: sqlite3.Connection, start_query: str, end_query: str, max_depth: int) -> dict:
    start_matches = find_entities(conn, start_query)
    end_matches = find_entities(conn, end_query)
    if not start_matches or not end_matches:
        return {"start": start_query, "end": end_query, "path": None, "reason": "missing endpoint"}
    start = start_matches[0]["id"]
    target = end_matches[0]["id"]
    neighbors: dict[str, list[tuple[str, str]]] = {}
    edges_by_id: dict[str, dict] = {}
    for row in conn.execute("select id, source, target from edges"):
        neighbors.setdefault(row["source"], []).append((row["target"], row["id"]))
        neighbors.setdefault(row["target"], []).append((row["source"], row["id"]))
    for row in conn.execute("select * from edges"):
        edges_by_id[row["id"]] = dict(row)
    queue = deque([(start, [])])
    seen = {start}
    while queue:
        node, path = queue.popleft()
        if node == target:
            entity_ids = [start] + [step["to"] for step in path]
            entities = {
                row["id"]: dict(row)
                for row in conn.execute(
                    f"select * from entities where id in ({','.join('?' for _ in entity_ids)})",
                    entity_ids,
                )
            }
            return {
                "start": dict(start_matches[0]),
                "end": dict(end_matches[0]),
                "path": [
                    {
                        "from": entities.get(step["from"], {"name": step["from"]})["name"],
                        "to": entities.get(step["to"], {"name": step["to"]})["name"],
                        "edge": step["edge"],
                        "relation": edges_by_id.get(step["edge"], {}).get("relation"),
                        "polarity": edges_by_id.get(step["edge"], {}).get("polarity"),
                    }
                    for step in path
                ],
            }
        if len(path) >= max_depth:
            continue
        for next_node, edge_id in neighbors.get(node, []):
            if next_node in seen:
                continue
            seen.add(next_node)
            queue.append((next_node, path + [{"from": node, "to": next_node, "edge": edge_id}]))
    return {"start": dict(start_matches[0]), "end": dict(end_matches[0]), "path": None}


def structural_recall(workspace: Path, limit: int) -> list[dict]:
    path = workspace / "memory" / "graph" / "structural-recall.jsonl"
    if not path.exists():
        return []
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
        if len(rows) >= limit:
            break
    return rows


def relation_summary(conn: sqlite3.Connection) -> list[dict]:
    return [
        dict(row)
        for row in conn.execute(
            """
            select relation, polarity, extraction, count(*) as edge_count, sum(count) as signal_count,
                   round(avg(confidence), 4) as avg_confidence
            from edges
            group by relation, polarity, extraction
            order by signal_count desc, edge_count desc
            """
        )
    ]


def pykeen_similar(conn: sqlite3.Connection, workspace: Path, query: str, limit: int) -> dict:
    rows = load_jsonl(workspace / "memory" / "graph" / "pykeen" / "similar.jsonl")
    if not query:
        return {"query": query, "matches": [], "similar": rows[:limit]}
    matches = find_entities(conn, query)
    exact_match = next((row for row in matches if str(row["name"]).lower() == query.lower()), None)
    primary_match = exact_match or (matches[0] if matches else None)
    ids = {primary_match["id"]} if primary_match is not None else set()
    filtered = [
        row
        for row in rows
        if row.get("source") in ids or row.get("target") in ids
    ][:limit]
    if not filtered and ids:
        embeddings = load_jsonl(workspace / "memory" / "graph" / "pykeen" / "entity-embeddings.jsonl")
        vectors = {
            str(row.get("id")): [float(value) for value in row.get("vector", [])]
            for row in embeddings
            if isinstance(row.get("id"), str) and isinstance(row.get("vector"), list)
        }
        names = {
            row["id"]: row["name"]
            for row in conn.execute("select id, name from entities")
        }
        scored: list[dict] = []
        for source_id in ids:
            source_vector = vectors.get(source_id)
            if not source_vector:
                continue
            for target_id, target_vector in vectors.items():
                if target_id == source_id:
                    continue
                score = cosine(source_vector, target_vector)
                if score <= 0:
                    continue
                scored.append(
                    {
                        "schemaVersion": 1,
                        "source": source_id,
                        "sourceName": names.get(source_id, source_id),
                        "target": target_id,
                        "targetName": names.get(target_id, target_id),
                        "similarity": round(score, 6),
                        "computed": True,
                    }
                )
        scored.sort(key=lambda row: row["similarity"], reverse=True)
        filtered = scored[:limit]
    return {"query": query, "matches": [dict(row) for row in matches], "similar": filtered}


def normalize_relation_query(value: str) -> str:
    return value.strip().upper().replace("-", "_").replace(" ", "_")


def pykeen_predict(conn: sqlite3.Connection, workspace: Path, query: str, relation: str, limit: int) -> dict:
    rows = load_jsonl(workspace / "memory" / "graph" / "pykeen" / "link-predictions.jsonl")
    matches = find_entities(conn, query)
    ids = {row["id"] for row in matches}
    normalized_relation = normalize_relation_query(relation)
    filtered = [
        row
        for row in rows
        if row.get("source") in ids and (
            not normalized_relation or normalize_relation_query(str(row.get("relation", ""))) == normalized_relation
        )
    ][:limit]
    return {
        "query": query,
        "relation": normalized_relation,
        "matches": [dict(row) for row in matches],
        "predictions": filtered,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Query OpenClaw graph memory artifacts.")
    parser.add_argument("--workspace", default=".", help="Agent workspace directory")
    parser.add_argument("--db", default="", help="graph.sqlite path")
    parser.add_argument("--stats", action="store_true")
    parser.add_argument("--entity", default="", help="Entity name or id to inspect")
    parser.add_argument("--connections", default="", help="Entity name or id for neighbor query")
    parser.add_argument("--path", nargs=2, metavar=("START", "END"), help="Find a short graph path")
    parser.add_argument("--structural-recall", type=int, default=0, help="Print top structural recall rows")
    parser.add_argument("--relations", action="store_true", help="Summarize relation types")
    parser.add_argument("--similar", default="", help="Find structurally similar entities from PyKEEN artifacts")
    parser.add_argument("--predict", nargs=2, metavar=("HEAD", "RELATION"), help="Predict likely tails for HEAD + RELATION")
    parser.add_argument("--limit", type=int, default=12)
    args = parser.parse_args()

    workspace = Path(args.workspace).expanduser().resolve()
    db_path = Path(args.db).expanduser().resolve() if args.db else default_db(workspace)

    if args.structural_recall:
        print_json(structural_recall(workspace, args.structural_recall))
        return 0

    with connect(db_path) as conn:
        if args.stats:
            print_json(stats(conn))
        elif args.entity:
            print_json([dict(row) for row in find_entities(conn, args.entity)])
        elif args.connections:
            print_json(connections(conn, args.connections, args.limit))
        elif args.path:
            print_json(shortest_path(conn, args.path[0], args.path[1], max_depth=4))
        elif args.relations:
            print_json(relation_summary(conn))
        elif args.similar:
            print_json(pykeen_similar(conn, workspace, args.similar, args.limit))
        elif args.predict:
            print_json(pykeen_predict(conn, workspace, args.predict[0], args.predict[1], args.limit))
        else:
            print_json(stats(conn))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
