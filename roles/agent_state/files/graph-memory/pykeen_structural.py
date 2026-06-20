#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
from pathlib import Path
from typing import Iterable


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


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    tmp_path.replace(path)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.tmp")
    tmp_path.write_text(text, encoding="utf-8")
    tmp_path.replace(path)


def stable_vector(key: str, dim: int) -> list[float]:
    seed = int(hashlib.sha1(key.encode("utf-8")).hexdigest()[:16], 16)
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(dim)]


def normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0:
        return vector
    return [value / norm for value in vector]


def cosine(left: list[float], right: list[float]) -> float:
    return sum(a * b for a, b in zip(left, right))


def add_vectors(left: list[float], right: list[float]) -> list[float]:
    return [a + b for a, b in zip(left, right)]


def subtract_vectors(left: list[float], right: list[float]) -> list[float]:
    return [a - b for a, b in zip(left, right)]


def mean_vector(vectors: Iterable[list[float]], dim: int) -> list[float]:
    total = [0.0] * dim
    count = 0
    for vector in vectors:
        if len(vector) != dim:
            continue
        count += 1
        for index, value in enumerate(vector):
            total[index] += value
    if count == 0:
        return [0.0] * dim
    return normalize([value / count for value in total])


def fallback_embeddings(entities: list[dict], edges: list[dict], dim: int) -> dict[str, list[float]]:
    vectors = {entity["id"]: stable_vector(entity["id"], dim) for entity in entities if entity.get("id")}
    adjacency: dict[str, list[tuple[str, str]]] = {}
    for edge in edges:
        source = edge.get("source")
        target = edge.get("target")
        relation = edge.get("relation", "RELATES_TO")
        if not isinstance(source, str) or not isinstance(target, str):
            continue
        adjacency.setdefault(source, []).append((target, str(relation)))
        adjacency.setdefault(target, []).append((source, str(relation)))
    for _ in range(3):
        next_vectors: dict[str, list[float]] = {}
        for entity_id, vector in vectors.items():
            mixed = [0.65 * value for value in vector]
            neighbors = adjacency.get(entity_id, [])
            if neighbors:
                scale = 0.35 / max(1, len(neighbors))
                for neighbor_id, relation in neighbors:
                    neighbor = vectors.get(neighbor_id)
                    if not neighbor:
                        continue
                    relation_bias = stable_vector(relation, len(vector))
                    for index, value in enumerate(neighbor):
                        mixed[index] += scale * (value + 0.05 * relation_bias[index])
            next_vectors[entity_id] = normalize(mixed)
        vectors = next_vectors
    return vectors


def triples_from_edges(edges: list[dict]) -> list[tuple[str, str, str]]:
    triples: list[tuple[str, str, str]] = []
    for edge in edges:
        source = edge.get("source")
        target = edge.get("target")
        relation = edge.get("relation", "MENTIONED_WITH")
        if isinstance(source, str) and isinstance(target, str):
            triples.append((source, str(relation), target))
    return triples


def try_pykeen_embeddings(
    entities: list[dict],
    edges: list[dict],
    dim: int,
    epochs: int,
) -> tuple[dict[str, list[float]], str]:
    triples = triples_from_edges(edges)
    if not triples:
        return fallback_embeddings(entities, edges, dim), "fallback-empty"
    try:
        import numpy as np  # type: ignore
        import torch  # type: ignore
        from pykeen.pipeline import pipeline  # type: ignore
        from pykeen.triples import TriplesFactory  # type: ignore

        labeled = np.asarray([[head, relation, tail] for head, relation, tail in triples], dtype=str)
        factory = TriplesFactory.from_labeled_triples(labeled)
        result = pipeline(
            model="TransE",
            training=factory,
            testing=factory,
            validation=factory,
            model_kwargs={"embedding_dim": dim},
            training_kwargs={"num_epochs": epochs, "batch_size": min(256, max(1, len(triples)))},
            random_seed=13,
            device="cpu",
        )
        ids = torch.as_tensor(
            list(range(factory.num_entities)),
            dtype=torch.long,
            device=result.model.device,
        )
        tensor = result.model.entity_representations[0](indices=ids).detach().cpu().numpy()
        id_to_label = {idx: label for label, idx in factory.entity_to_id.items()}
        return {
            id_to_label[index]: normalize([float(value) for value in row.tolist()])
            for index, row in enumerate(tensor)
        }, "pykeen"
    except Exception:
        return fallback_embeddings(entities, edges, dim), "fallback"


def top_similar(vectors: dict[str, list[float]], limit: int) -> list[dict]:
    ids = sorted(vectors)
    rows: list[dict] = []
    for i, left in enumerate(ids):
        for right in ids[i + 1 :]:
            score = cosine(vectors[left], vectors[right])
            if score <= 0:
                continue
            rows.append({"schemaVersion": 1, "source": left, "target": right, "similarity": round(score, 6)})
    rows.sort(key=lambda row: row["similarity"], reverse=True)
    return rows[:limit]


def relation_vectors(vectors: dict[str, list[float]], edges: list[dict], dim: int) -> dict[str, list[float]]:
    grouped: dict[str, list[list[float]]] = {}
    for edge in edges:
        source = edge.get("source")
        target = edge.get("target")
        relation = str(edge.get("relation", "MENTIONED_WITH"))
        if not isinstance(source, str) or not isinstance(target, str):
            continue
        source_vector = vectors.get(source)
        target_vector = vectors.get(target)
        if not source_vector or not target_vector:
            continue
        grouped.setdefault(relation, []).append(subtract_vectors(target_vector, source_vector))
    return {relation: mean_vector(rows, dim) for relation, rows in grouped.items()}


def top_link_predictions(
    entities: list[dict],
    edges: list[dict],
    vectors: dict[str, list[float]],
    rel_vectors: dict[str, list[float]],
    limit: int,
) -> list[dict]:
    names = {entity["id"]: entity.get("name", entity["id"]) for entity in entities if entity.get("id")}
    ranked_entities = [
        entity["id"]
        for entity in sorted(
            entities,
            key=lambda item: (int(item.get("degree", 0) or 0), int(item.get("mentions", 0) or 0)),
            reverse=True,
        )
        if entity.get("id") in vectors
    ][:100]
    known = {
        (edge.get("source"), str(edge.get("relation", "MENTIONED_WITH")), edge.get("target"))
        for edge in edges
    }
    rows: list[dict] = []
    for source_id in ranked_entities:
        source_vector = vectors.get(source_id)
        if not source_vector:
            continue
        for relation, rel_vector in rel_vectors.items():
            target_probe = normalize(add_vectors(source_vector, rel_vector))
            for target_id in ranked_entities:
                if target_id == source_id or (source_id, relation, target_id) in known:
                    continue
                target_vector = vectors.get(target_id)
                if not target_vector:
                    continue
                score = cosine(target_probe, target_vector)
                if score <= 0:
                    continue
                rows.append(
                    {
                        "schemaVersion": 1,
                        "source": source_id,
                        "sourceName": names.get(source_id, source_id),
                        "relation": relation,
                        "target": target_id,
                        "targetName": names.get(target_id, target_id),
                        "score": round(score, 6),
                    }
                )
    rows.sort(key=lambda row: row["score"], reverse=True)
    return rows[:limit]


def build_pykeen_recall_rows(
    entities: list[dict],
    edges: list[dict],
    similar: list[dict],
    limit: int,
) -> list[dict]:
    names = {entity["id"]: entity.get("name", entity["id"]) for entity in entities if entity.get("id")}
    edge_by_entity: dict[str, dict] = {}
    for edge in sorted(edges, key=lambda item: (item.get("count", 0), item.get("confidence", 0)), reverse=True):
        for entity_id in [edge.get("source"), edge.get("target")]:
            if isinstance(entity_id, str) and entity_id not in edge_by_entity:
                edge_by_entity[entity_id] = edge
    rows: list[dict] = []
    for item in similar:
        edge = edge_by_entity.get(item["source"]) or edge_by_entity.get(item["target"])
        if not edge:
            continue
        score = min(0.99, max(0.45, 0.45 + 0.45 * float(item["similarity"])))
        rows.append(
            {
            "source": "pykeen",
            "schemaVersion": 1,
            "key": f"pykeen:{item['source']}:{item['target']}",
                "path": edge.get("sourcePath"),
                "startLine": edge.get("startLine", 1),
                "endLine": edge.get("endLine", edge.get("startLine", 1)),
                "snippet": edge.get("snippet", ""),
                "score": round(score, 4),
                "maxScore": round(score, 4),
                "signalCount": max(1, int(round(10 * float(item["similarity"])))),
                "entity": names.get(item["source"], item["source"]),
                "neighbor": names.get(item["target"], item["target"]),
                "relation": "STRUCTURALLY_SIMILAR",
                "lastSeenAt": edge.get("lastSeenAt"),
            }
        )
        if len(rows) >= limit:
            break
    return rows


def merge_structural_recall(path: Path, new_rows: list[dict]) -> None:
    existing = load_jsonl(path)
    merged: dict[str, dict] = {}
    for row in existing + new_rows:
        key = row.get("key")
        source = row.get("source", "graph")
        if isinstance(key, str):
            merged[f"{source}:{key}"] = row
    rows = sorted(
        merged.values(),
        key=lambda row: (float(row.get("score", 0) or 0), int(row.get("signalCount", 0) or 0)),
        reverse=True,
    )
    write_jsonl(path, rows)


def main() -> int:
    parser = argparse.ArgumentParser(description="Train/export PyKEEN-style graph memory embeddings.")
    parser.add_argument("--workspace", default=".", help="Agent workspace directory")
    parser.add_argument("--graph-dir", default="", help="Graph artifact directory")
    parser.add_argument("--dim", type=int, default=64)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--similar-limit", type=int, default=200)
    parser.add_argument("--prediction-limit", type=int, default=200)
    parser.add_argument("--recall-limit", type=int, default=120)
    args = parser.parse_args()

    workspace = Path(args.workspace).expanduser().resolve()
    graph_dir = Path(args.graph_dir).expanduser().resolve() if args.graph_dir else workspace / "memory" / "graph"
    entities = load_jsonl(graph_dir / "entities.jsonl")
    edges = load_jsonl(graph_dir / "edges.jsonl")
    vectors, backend = try_pykeen_embeddings(entities, edges, max(8, args.dim), max(1, args.epochs))
    names = {entity["id"]: entity.get("name", entity["id"]) for entity in entities if entity.get("id")}
    dim = len(next(iter(vectors.values()), [])) or max(8, args.dim)
    rel_vectors = relation_vectors(vectors, edges, dim)
    embedding_rows = [
        {
            "id": entity_id,
            "schemaVersion": 1,
            "name": names.get(entity_id, entity_id),
            "vector": [round(value, 8) for value in vector],
            "backend": backend,
        }
        for entity_id, vector in sorted(vectors.items())
    ]
    relation_rows = [
        {
            "relation": relation,
            "schemaVersion": 1,
            "vector": [round(value, 8) for value in vector],
            "backend": backend,
        }
        for relation, vector in sorted(rel_vectors.items())
    ]
    similar = top_similar(vectors, max(0, args.similar_limit))
    for row in similar:
        row["sourceName"] = names.get(row["source"], row["source"])
        row["targetName"] = names.get(row["target"], row["target"])
    predictions = top_link_predictions(
        entities=entities,
        edges=edges,
        vectors=vectors,
        rel_vectors=rel_vectors,
        limit=max(0, args.prediction_limit),
    )
    recall_rows = build_pykeen_recall_rows(entities, edges, similar, max(0, args.recall_limit))
    pykeen_dir = graph_dir / "pykeen"
    write_jsonl(pykeen_dir / "entity-embeddings.jsonl", embedding_rows)
    write_jsonl(pykeen_dir / "relation-embeddings.jsonl", relation_rows)
    write_jsonl(pykeen_dir / "similar.jsonl", similar)
    write_jsonl(pykeen_dir / "link-predictions.jsonl", predictions)
    write_text(
        pykeen_dir / "training-triples.tsv",
        "".join(f"{head}\t{relation}\t{tail}\n" for head, relation, tail in triples_from_edges(edges)),
    )
    merge_structural_recall(graph_dir / "structural-recall.jsonl", recall_rows)
    write_text(
        pykeen_dir / "metadata.json",
        json.dumps(
            {
                "backend": backend,
                "entityCount": len(entities),
                "edgeCount": len(edges),
                "embeddingCount": len(embedding_rows),
                "relationEmbeddingCount": len(relation_rows),
                "similarCount": len(similar),
                "predictionCount": len(predictions),
                "recallCount": len(recall_rows),
                "format": "openclaw.pykeen-structural.v1",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
    )
    print(f"pykeen structural: backend={backend} embeddings={len(embedding_rows)} recall={len(recall_rows)} -> {pykeen_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
