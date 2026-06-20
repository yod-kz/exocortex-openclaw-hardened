#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


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


def normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0:
        return vector
    return [value / norm for value in vector]


def add_vectors(left: list[float], right: list[float]) -> list[float]:
    return [a + b for a, b in zip(left, right)]


def source_exists(workspace: Path, row: dict) -> bool:
    path = row.get("sourcePath") or row.get("path")
    if not isinstance(path, str) or not path:
        return False
    candidate = (workspace / path).resolve()
    try:
        candidate.relative_to(workspace.resolve())
    except ValueError:
        return False
    return candidate.exists()


def rank_known_edges(
    edges: list[dict],
    entity_vectors: dict[str, list[float]],
    relation_vectors: dict[str, list[float]],
    limit: int,
) -> dict:
    ranks: list[int] = []
    entity_ids = sorted(entity_vectors)
    for edge in edges[:limit]:
        source = edge.get("source")
        target = edge.get("target")
        relation = str(edge.get("relation", ""))
        if not isinstance(source, str) or not isinstance(target, str):
            continue
        source_vector = entity_vectors.get(source)
        target_vector = entity_vectors.get(target)
        relation_vector = relation_vectors.get(relation)
        if not source_vector or not target_vector or not relation_vector:
            continue
        probe = normalize(add_vectors(source_vector, relation_vector))
        scored = sorted(
            (
                (candidate, cosine(probe, vector))
                for candidate, vector in entity_vectors.items()
                if candidate != source
            ),
            key=lambda item: item[1],
            reverse=True,
        )
        for index, (candidate, _score) in enumerate(scored, start=1):
            if candidate == target:
                ranks.append(index)
                break
    if not ranks:
        return {"sampled": 0, "hitAt10": 0.0, "mrr": 0.0}
    hit_at_10 = sum(1 for rank in ranks if rank <= 10) / len(ranks)
    mrr = sum(1 / rank for rank in ranks) / len(ranks)
    return {
        "sampled": len(ranks),
        "candidateCount": len(entity_ids),
        "hitAt10": round(hit_at_10, 4),
        "mrr": round(mrr, 4),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate OpenClaw graph memory artifacts.")
    parser.add_argument("--workspace", default=".", help="Agent workspace directory")
    parser.add_argument("--max-structural-recall", type=int, default=500)
    parser.add_argument("--min-typed-ratio", type=float, default=0.0)
    parser.add_argument("--min-hit-at-10", type=float, default=0.0)
    parser.add_argument("--ranking-sample", type=int, default=50)
    parser.add_argument("--require-pykeen", action="store_true")
    args = parser.parse_args()

    workspace = Path(args.workspace).expanduser().resolve()
    graph_dir = workspace / "memory" / "graph"
    pykeen_dir = graph_dir / "pykeen"
    metadata = load_json(graph_dir / "metadata.json")
    entities = load_jsonl(graph_dir / "entities.jsonl")
    edges = load_jsonl(graph_dir / "edges.jsonl")
    recall = load_jsonl(graph_dir / "structural-recall.jsonl")
    entity_embeddings = load_jsonl(pykeen_dir / "entity-embeddings.jsonl")
    relation_embeddings = load_jsonl(pykeen_dir / "relation-embeddings.jsonl")
    similar = load_jsonl(pykeen_dir / "similar.jsonl")
    predictions = load_jsonl(pykeen_dir / "link-predictions.jsonl")

    failures: list[str] = []
    if metadata.get("format") != "openclaw.graph-memory.v2":
        failures.append("metadata format is not openclaw.graph-memory.v2")
    if len(recall) > args.max_structural_recall:
        failures.append(f"structural recall has {len(recall)} rows, above {args.max_structural_recall}")

    provenance_count = sum(1 for edge in edges if source_exists(workspace, edge))
    typed_count = sum(1 for edge in edges if edge.get("relation") not in {"", None, "MENTIONED_WITH"})
    polarity_count = sum(1 for edge in edges if edge.get("polarity") in {"affirmed", "negated"})
    if edges and provenance_count != len(edges):
        failures.append(f"{len(edges) - provenance_count} edges lack valid source provenance")
    if edges and polarity_count != len(edges):
        failures.append(f"{len(edges) - polarity_count} edges lack polarity")

    typed_ratio = typed_count / len(edges) if edges else 0.0
    if typed_ratio < args.min_typed_ratio:
        failures.append(f"typed relation ratio {typed_ratio:.4f} below {args.min_typed_ratio:.4f}")

    entity_vectors = {
        str(row.get("id")): [float(value) for value in row.get("vector", [])]
        for row in entity_embeddings
        if isinstance(row.get("id"), str) and isinstance(row.get("vector"), list)
    }
    relation_vectors = {
        str(row.get("relation")): [float(value) for value in row.get("vector", [])]
        for row in relation_embeddings
        if isinstance(row.get("relation"), str) and isinstance(row.get("vector"), list)
    }
    ranking = rank_known_edges(edges, entity_vectors, relation_vectors, max(0, args.ranking_sample))
    if ranking["hitAt10"] < args.min_hit_at_10:
        failures.append(f"hitAt10 {ranking['hitAt10']:.4f} below {args.min_hit_at_10:.4f}")

    if args.require_pykeen:
        if not entity_embeddings:
            failures.append("missing entity embeddings")
        if not relation_embeddings:
            failures.append("missing relation embeddings")
        if not similar:
            failures.append("missing similarity rows")
        if not (pykeen_dir / "training-triples.tsv").exists():
            failures.append("missing training triples")

    report = {
        "ok": not failures,
        "failures": failures,
        "format": metadata.get("format"),
        "entityCount": len(entities),
        "edgeCount": len(edges),
        "typedRelationRatio": round(typed_ratio, 4),
        "provenanceCoverage": round(provenance_count / len(edges), 4) if edges else 1.0,
        "polarityCoverage": round(polarity_count / len(edges), 4) if edges else 1.0,
        "structuralRecallCount": len(recall),
        "embeddingCount": len(entity_embeddings),
        "relationEmbeddingCount": len(relation_embeddings),
        "similarCount": len(similar),
        "predictionCount": len(predictions),
        "ranking": ranking,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
