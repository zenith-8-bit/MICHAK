from __future__ import annotations

from pathlib import Path

import numpy as np
from astropy.io import fits


def _make_field(seed: int, include_transient: bool) -> np.ndarray:
    rng = np.random.default_rng(seed)
    height, width = 256, 256
    image = rng.normal(1000.0, 5.0, (height, width))

    # A simple Gaussian point-spread function; intentionally synthetic.
    yy, xx = np.mgrid[0:height, 0:width]
    stars = [
        (35.4, 40.2, 350.0),
        (72.0, 210.5, 500.0),
        (119.7, 80.1, 650.0),
        (180.2, 170.8, 800.0),
        (220.4, 55.3, 420.0),
        (148.0, 224.0, 550.0),
    ]
    if include_transient:
        stars.append((202.5, 115.5, 1100.0))

    sigma = 1.6
    for x, y, amplitude in stars:
        image += amplitude * np.exp(-((xx - x) ** 2 + (yy - y) ** 2) / (2 * sigma**2))
    return image


def create_demo(directory: str | Path) -> tuple[Path, Path]:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    ref = _make_field(seed=1, include_transient=False)
    new = _make_field(seed=2, include_transient=True)
    header = fits.Header()
    header["OBJECT"] = "NOVA SYNTHETIC FIELD"
    header["FILTER"] = "SYNTHETIC"
    header["EXPTIME"] = 60.0
    header["BUNIT"] = "arbitrary"
    ref_path = directory / "reference.fits"
    new_path = directory / "new.fits"
    fits.writeto(ref_path, ref.astype(np.float32), header=header, overwrite=True)
    fits.writeto(new_path, new.astype(np.float32), header=header, overwrite=True)
    return ref_path, new_path
