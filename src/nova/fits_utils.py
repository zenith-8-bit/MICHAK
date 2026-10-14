from __future__ import annotations

from pathlib import Path
from typing import Any

import numpy as np
from astropy.io import fits


def load_image(path: str | Path, hdu_index: int = 0) -> tuple[np.ndarray, fits.Header]:
    """Load a 2-D FITS image and return image data plus a copied header."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"FITS file not found: {path}")

    with fits.open(path, memmap=False) as hdul:
        if hdu_index < 0 or hdu_index >= len(hdul):
            raise ValueError(f"HDU index {hdu_index} is outside this FITS file (0..{len(hdul)-1}).")

        data = hdul[hdu_index].data
        header = hdul[hdu_index].header.copy()

        if data is None:
            # Try the first image HDU containing data if the requested HDU is empty.
            for hdu in hdul:
                if hdu.data is not None and np.asarray(hdu.data).ndim == 2:
                    data = hdu.data
                    header = hdu.header.copy()
                    break

        if data is None:
            raise ValueError("No image data found in this FITS file.")
        image = np.asarray(data, dtype=np.float64)

    # Common science images are 2-D. For cubes, choose the first plane explicitly.
    if image.ndim == 3 and image.shape[0] > 0:
        image = image[0]
    if image.ndim != 2:
        raise ValueError(f"Expected a 2-D image (or 3-D cube), got shape {image.shape}.")
    if not np.isfinite(image).any():
        raise ValueError("Image contains no finite pixel values.")

    return image, header


def image_summary(image: np.ndarray, header: fits.Header) -> dict[str, Any]:
    finite = image[np.isfinite(image)]
    return {
        "shape": image.shape,
        "finite_fraction": float(finite.size / image.size),
        "minimum": float(np.min(finite)),
        "median": float(np.median(finite)),
        "maximum": float(np.max(finite)),
        "mean": float(np.mean(finite)),
        "std": float(np.std(finite)),
        "object": header.get("OBJECT", "unknown"),
        "date_obs": header.get("DATE-OBS", "unknown"),
        "filter": header.get("FILTER", "unknown"),
        "exptime": header.get("EXPTIME", "unknown"),
        "bunit": header.get("BUNIT", "unknown"),
    }
