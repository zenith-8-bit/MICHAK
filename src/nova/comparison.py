from __future__ import annotations

import math
from typing import Iterable

import numpy as np
from scipy.spatial import cKDTree

from .detection import detect_sources


def compare_images(
    reference: np.ndarray,
    new_image: np.ndarray,
    threshold_sigma: float = 5.0,
    min_separation: float = 5.0,
    match_radius: float = 4.0,
    brighten_ratio: float = 2.0,
) -> tuple[list[dict], dict]:
    """Compare detected sources in two already-aligned, same-grid images."""
    if reference.shape != new_image.shape:
        raise ValueError(
            f"Image shapes differ: reference={reference.shape}, new={new_image.shape}. "
            "This MVP requires images already aligned to the same pixel grid."
        )
    if match_radius <= 0:
        raise ValueError("match_radius must be greater than zero.")
    if brighten_ratio <= 1:
        raise ValueError("brighten_ratio must be greater than 1.")

    ref_sources, ref_meta = detect_sources(reference, threshold_sigma, min_separation)
    new_sources, new_meta = detect_sources(new_image, threshold_sigma, min_separation)

    ref_points = np.array([[s["x"], s["y"]] for s in ref_sources], dtype=float)
    tree = cKDTree(ref_points) if len(ref_points) else None

    candidates: list[dict] = []
    matched_ref: set[int] = set()
    for source in new_sources:
        match_idx = None
        distance = math.inf
        if tree is not None:
            dist, idx = tree.query([source["x"], source["y"]], k=1)
            distance, match_idx = float(dist), int(idx)
            if distance > match_radius:
                match_idx = None

        status = "NOT_FLAGGED"
        ref_flux = None
        ref_id = None
        ratio = None
        if match_idx is None:
            status = "NEW_CANDIDATE"
        else:
            matched_ref.add(match_idx)
            ref = ref_sources[match_idx]
            ref_flux = float(ref["flux"])
            ref_id = int(ref["source_id"])
            ratio = float(source["flux"] / max(ref_flux, 1e-12))
            if ratio >= brighten_ratio:
                status = "BRIGHTENED_CANDIDATE"

        if status != "NOT_FLAGGED":
            candidates.append({
                "candidate_id": f"NOVA-{len(candidates)+1:04d}",
                "status": status,
                "x": float(source["x"]),
                "y": float(source["y"]),
                "new_flux": float(source["flux"]),
                "reference_flux": ref_flux,
                "flux_ratio": ratio,
                "nearest_reference_id": ref_id,
                "match_distance_px": None if match_idx is None else distance,
                "significance": float(source["significance"]),
                "sharpness": float(source["sharpness"]),
            })

    metadata = {
        "reference_source_count": len(ref_sources),
        "new_source_count": len(new_sources),
        "candidate_count": len(candidates),
        "new_candidate_count": sum(c["status"] == "NEW_CANDIDATE" for c in candidates),
        "brightened_candidate_count": sum(c["status"] == "BRIGHTENED_CANDIDATE" for c in candidates),
        "reference_detection": ref_meta,
        "new_detection": new_meta,
        "match_radius": match_radius,
        "brighten_ratio": brighten_ratio,
    }
    return candidates, metadata
