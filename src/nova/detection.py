from __future__ import annotations

import numpy as np
from astropy.stats import SigmaClip
from photutils.background import Background2D, MedianBackground
from photutils.detection import DAOStarFinder


def detect_sources(
    image: np.ndarray,
    threshold_sigma: float = 5.0,
    min_separation: float = 5.0,
) -> tuple[list[dict], dict]:
    """Detect point sources in an image using a robust background estimate.

    Coordinates are zero-based pixel positions. Flux is a simple local
    background-subtracted aperture-like sum from Photutils' DAOStarFinder
    output, not precision-calibrated photometry.
    """
    if threshold_sigma <= 0:
        raise ValueError("threshold_sigma must be greater than zero.")
    if min_separation <= 0:
        raise ValueError("min_separation must be greater than zero.")

    work = np.asarray(image, dtype=float)
    finite = np.isfinite(work)
    if finite.sum() < 25:
        raise ValueError("Image has too few finite pixels for source detection.")

    # Replace non-finite pixels with the finite median for the background step.
    finite_median = float(np.nanmedian(work))
    clean = np.where(finite, work, finite_median)

    # Small images may not support Background2D's default mesh settings.
    min_dim = min(clean.shape)
    box = max(8, min(64, min_dim // 4))
    if box >= min_dim:
        box = max(4, min_dim // 2)

    try:
        bkg = Background2D(
            clean,
            box_size=(box, box),
            filter_size=(3, 3),
            sigma_clip=SigmaClip(sigma=3.0, maxiters=5),
            bkg_estimator=MedianBackground(),
            exclude_percentile=50,
        )
        background = bkg.background
        background_rms = bkg.background_rms
        global_background = float(np.nanmedian(background))
        global_rms = float(np.nanmedian(background_rms))
    except Exception:
        # Robust fallback for tiny or unusually shaped images.
        global_background = float(np.nanmedian(clean))
        mad = float(np.nanmedian(np.abs(clean - global_background)))
        global_rms = max(1.4826 * mad, float(np.nanstd(clean)) * 0.1, 1e-12)
        background = np.full(clean.shape, global_background)
        background_rms = np.full(clean.shape, global_rms)

    # DAOStarFinder uses one threshold; a robust global RMS is a practical MVP.
    threshold = max(threshold_sigma * global_rms, 1e-12)
    finder = DAOStarFinder(
        threshold=threshold,
        fwhm=max(2.0, min_separation / 2.5),
        sharplo=0.2,
        sharphi=1.0,
        roundlo=-1.0,
        roundhi=1.0,
    )

    sources = finder(clean - background)
    results: list[dict] = []
    if sources is not None:
        for index, row in enumerate(sources):
            x = float(row["xcentroid"])
            y = float(row["ycentroid"])
            flux = float(row["flux"])
            peak = float(row["peak"]) if "peak" in sources.colnames else float("nan")
            results.append({
                "source_id": index + 1,
                "x": x,
                "y": y,
                "flux": flux,
                "peak": peak,
                "significance": float(peak / global_rms) if global_rms > 0 else float("nan"),
                "sharpness": float(row["sharpness"]) if "sharpness" in sources.colnames else float("nan"),
                "roundness1": float(row["roundness1"]) if "roundness1" in sources.colnames else float("nan"),
            })

    results.sort(key=lambda item: item["flux"], reverse=True)
    for index, item in enumerate(results, start=1):
        item["source_id"] = index

    metadata = {
        "background": global_background,
        "background_rms": global_rms,
        "threshold": threshold,
        "threshold_sigma": threshold_sigma,
        "count": len(results),
    }
    return results, metadata
