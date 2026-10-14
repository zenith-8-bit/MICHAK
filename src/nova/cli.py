from __future__ import annotations

import csv
from pathlib import Path
from typing import Optional

import numpy as np
import typer
from astropy.io import fits
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from .comparison import compare_images
from .demo import create_demo
from .detection import detect_sources
from .fits_utils import image_summary, load_image
from .plotting import save_comparison_plot, save_scan_plot

app = typer.Typer(
    name="nova",
    help="NOVA: a local-first CLI for finding transient-source candidates in FITS images.",
    no_args_is_help=True,
)
console = Console()


def write_csv(rows: list[dict], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        # Still create a useful empty CSV with a minimal header.
        with output.open("w", newline="", encoding="utf-8") as handle:
            handle.write("no_candidates\n")
        return
    keys = list(dict.fromkeys(key for row in rows for key in row.keys()))
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


@app.command()
def inspect(
    image: Path = typer.Argument(..., exists=True, readable=True, help="FITS image path"),
    hdu: int = typer.Option(0, "--hdu", help="HDU index to read"),
) -> None:
    """Show FITS image dimensions, basic statistics, and selected metadata."""
    try:
        data, header = load_image(image, hdu)
        summary = image_summary(data, header)
    except Exception as exc:
        console.print(f"[red]Could not inspect image:[/red] {exc}")
        raise typer.Exit(code=1)

    table = Table(title=f"NOVA // FITS INSPECT — {image.name}")
    table.add_column("Property", style="cyan")
    table.add_column("Value")
    values = [
        ("Shape (rows, cols)", str(summary["shape"])),
        ("Finite pixel fraction", f'{summary["finite_fraction"]:.4f}'),
        ("Minimum", f'{summary["minimum"]:.4f}'),
        ("Median", f'{summary["median"]:.4f}'),
        ("Maximum", f'{summary["maximum"]:.4f}'),
        ("Mean", f'{summary["mean"]:.4f}'),
        ("Standard deviation", f'{summary["std"]:.4f}'),
        ("Object", str(summary["object"])),
        ("Observation time", str(summary["date_obs"])),
        ("Filter", str(summary["filter"])),
        ("Exposure (s)", str(summary["exptime"])),
        ("BUNIT", str(summary["bunit"])),
    ]
    for key, value in values:
        table.add_row(key, value)
    console.print(table)


@app.command()
def scan(
    image: Path = typer.Argument(..., exists=True, readable=True, help="FITS image to scan"),
    output: Path = typer.Option(Path("sources.csv"), "--output", "-o", help="CSV output path"),
    plot: Optional[Path] = typer.Option(None, "--plot", help="Optional annotated PNG output"),
    hdu: int = typer.Option(0, "--hdu", help="HDU index to read"),
    threshold_sigma: float = typer.Option(5.0, "--threshold-sigma", min=0.1),
    min_separation: float = typer.Option(5.0, "--min-separation", min=0.1),
) -> None:
    """Detect point-like sources in a FITS image and export a CSV catalog."""
    try:
        data, _ = load_image(image, hdu)
        sources, meta = detect_sources(data, threshold_sigma, min_separation)
        write_csv(sources, output)
        if plot:
            save_scan_plot(data, sources, plot, image.name)
    except Exception as exc:
        console.print(f"[red]Scan failed:[/red] {exc}")
        raise typer.Exit(code=1)

    console.print(Panel.fit(
        f"[bold]Image:[/bold] {image}\n"
        f"[bold]Detected sources:[/bold] {meta['count']}\n"
        f"[bold]Estimated background:[/bold] {meta['background']:.3f}\n"
        f"[bold]Estimated noise RMS:[/bold] {meta['background_rms']:.3f}\n"
        f"[bold]Threshold:[/bold] {meta['threshold']:.3f}",
        title="NOVA // SCAN COMPLETE",
    ))
    console.print(f"CSV saved: [green]{output.resolve()}[/green]")
    if plot:
        console.print(f"Plot saved: [green]{plot.resolve()}[/green]")
    console.print("[yellow]Detections are image sources, not confirmed new astronomical objects.[/yellow]")


@app.command()
def compare(
    reference: Path = typer.Argument(..., exists=True, readable=True, help="Earlier/reference FITS image"),
    new_image: Path = typer.Argument(..., exists=True, readable=True, help="Later/new FITS image"),
    output: Path = typer.Option(Path("candidates.csv"), "--output", "-o", help="Candidate CSV output"),
    plot: Optional[Path] = typer.Option(None, "--plot", help="Optional comparison PNG"),
    hdu: int = typer.Option(0, "--hdu", help="HDU index to read from both images"),
    threshold_sigma: float = typer.Option(5.0, "--threshold-sigma", min=0.1),
    min_separation: float = typer.Option(5.0, "--min-separation", min=0.1),
    match_radius: float = typer.Option(4.0, "--match-radius", min=0.1),
    brighten_ratio: float = typer.Option(2.0, "--brighten-ratio", min=1.01),
) -> None:
    """Compare source catalogs from aligned images and flag candidate changes."""
    try:
        ref, _ = load_image(reference, hdu)
        new, _ = load_image(new_image, hdu)
        candidates, meta = compare_images(
            ref, new,
            threshold_sigma=threshold_sigma,
            min_separation=min_separation,
            match_radius=match_radius,
            brighten_ratio=brighten_ratio,
        )
        write_csv(candidates, output)
        if plot:
            save_comparison_plot(ref, new, candidates, plot)
    except Exception as exc:
        console.print(f"[red]Comparison failed:[/red] {exc}")
        raise typer.Exit(code=1)

    table = Table(title="NOVA // CANDIDATE SUMMARY")
    table.add_column("Metric", style="cyan")
    table.add_column("Count / Value", justify="right")
    table.add_row("Reference sources", str(meta["reference_source_count"]))
    table.add_row("New-image sources", str(meta["new_source_count"]))
    table.add_row("New candidates", str(meta["new_candidate_count"]))
    table.add_row("Brightened candidates", str(meta["brightened_candidate_count"]))
    console.print(table)
    console.print(f"Candidate CSV saved: [green]{output.resolve()}[/green]")
    if plot:
        console.print(f"Comparison plot saved: [green]{plot.resolve()}[/green]")
    console.print(
        "[yellow]Caution:[/yellow] images must already be aligned and comparably calibrated. "
        "Flags are candidates only, not confirmed transients."
    )


@app.command()
def demo(
    directory: Path = typer.Option(Path("demo-data"), "--directory", "-d", help="Where to write synthetic FITS files"),
) -> None:
    """Create a synthetic FITS pair to smoke-test NOVA without downloading data."""
    try:
        reference, new_image = create_demo(directory)
    except Exception as exc:
        console.print(f"[red]Could not create demo:[/red] {exc}")
        raise typer.Exit(code=1)
    console.print(Panel.fit(
        f"Created synthetic reference: {reference.resolve()}\n"
        f"Created synthetic new image: {new_image.resolve()}\n\n"
        f"Next:\n"
        f"  nova scan {new_image}\n"
        f"  nova compare {reference} {new_image} --output demo-candidates.csv --plot demo-compare.png",
        title="NOVA // DEMO DATA READY",
    ))


if __name__ == "__main__":
    app()
