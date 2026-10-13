from __future__ import annotations

from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from astropy.visualization import ImageNormalize, PercentileInterval, SqrtStretch


def save_scan_plot(image: np.ndarray, sources: list[dict], output: str | Path, title: str) -> None:
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(10, 8))
    norm = ImageNormalize(image, interval=PercentileInterval(99.5), stretch=SqrtStretch())
    ax.imshow(image, origin="lower", cmap="gray", norm=norm)
    if sources:
        ax.scatter([s["x"] for s in sources], [s["y"] for s in sources],
                   s=50, facecolors="none", edgecolors="red", linewidths=0.8)
    ax.set_title(f"{title} — {len(sources)} detected sources")
    ax.set_xlabel("X pixel (zero-based)")
    ax.set_ylabel("Y pixel (zero-based)")
    fig.tight_layout()
    fig.savefig(output, dpi=150)
    plt.close(fig)


def save_comparison_plot(
    reference: np.ndarray,
    new_image: np.ndarray,
    candidates: list[dict],
    output: str | Path,
) -> None:
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    for ax, image, title in zip(axes[:2], [reference, new_image], ["Reference", "New observation"]):
        norm = ImageNormalize(image, interval=PercentileInterval(99.5), stretch=SqrtStretch())
        ax.imshow(image, origin="lower", cmap="gray", norm=norm)
        ax.set_title(title)
        ax.set_xlabel("X pixel")
        ax.set_ylabel("Y pixel")
    residual = new_image - reference
    limit = float(np.nanpercentile(np.abs(residual), 99.5))
    limit = max(limit, 1e-12)
    axes[2].imshow(residual, origin="lower", cmap="coolwarm", vmin=-limit, vmax=limit)
    axes[2].set_title("New − reference (not PSF-matched)")
    axes[2].set_xlabel("X pixel")
    axes[2].set_ylabel("Y pixel")
    for candidate in candidates:
        for ax in axes:
            ax.scatter(candidate["x"], candidate["y"], s=55, facecolors="none", edgecolors="yellow")
    fig.suptitle(f"NOVA candidates: {len(candidates)}")
    fig.tight_layout()
    fig.savefig(output, dpi=150)
    plt.close(fig)
