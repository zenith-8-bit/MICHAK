# NOVA — Astronomical Transient Detection CLI (MVP)

NOVA is a local-first command-line prototype for examining astronomical FITS images and finding **candidate** sources that are new or brighter compared with a reference observation.

It is a research/learning tool, not an observatory-grade discovery pipeline. Candidate detections can be caused by noise, cosmic rays, bad pixels, image misalignment, or calibration differences. It does not confirm a new star or supernova.

## MVP features

- Inspect a FITS image and detect point-like sources with Astropy + Photutils.
- Compare a reference FITS image against a new FITS image using source catalogs.
- Export source/candidate tables to CSV.
- Create a simple diagnostic plot for a source scan.
- Keep the image analysis local; no API key or network connection is required.

## Requirements

- Python 3.10+
- FITS images with a 2-D science image (or a FITS file whose primary HDU contains one).
- Calibrated images are strongly recommended for comparisons.

## Install

### Windows PowerShell

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -e .
nova --help
```

If PowerShell blocks activation, run this for the current terminal only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
```

### Linux / macOS

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -e .
nova --help
```

## Commands

### 1. Inspect a FITS image

```bash
nova inspect path/to/image.fits
```

Shows the selected HDU, image dimensions, finite-pixel fraction, basic statistics, and useful header fields if available.

### 2. Detect sources in one image

```bash
nova scan path/to/image.fits --output sources.csv --plot scan.png
```

Optional flags:

- `--threshold-sigma 5.0`: detection threshold in background standard deviations.
- `--min-separation 5`: approximate minimum source separation in pixels.
- `--hdu 0`: FITS HDU index to read.

The CSV includes pixel coordinates, approximate flux, peak value, and detection significance. Pixel coordinates are zero-based.

### 3. Compare reference and new observations

```bash
nova compare reference.fits new.fits --output candidates.csv --plot comparison.png
```

NOVA detects sources in both images and matches detections by pixel position. Sources in the new image without a nearby reference detection are marked `NEW_CANDIDATE`; matched sources that are substantially brighter can be marked `BRIGHTENED_CANDIDATE`.

Important limitations:
- The two images must already be aligned and use the same pixel grid.
- They should have comparable calibration, exposure, filter, and background treatment.
- This MVP compares source catalogs; it does not perform PSF-matched image subtraction.
- It does not yet cross-match SIMBAD, Gaia, TNS, or a live alert broker.

### 4. Try the built-in synthetic demo

```bash
nova demo --directory demo-data
nova scan demo-data/new.fits --output demo-sources.csv --plot demo-scan.png
nova compare demo-data/reference.fits demo-data/new.fits --output demo-candidates.csv --plot demo-compare.png
```

The demo creates two synthetic, aligned FITS images with stable stars plus one added source. It is a smoke test for the CLI, not real astronomical evidence.

## Output interpretation

`NEW_CANDIDATE` means a source was detected in the new image but no source was matched within the configured radius in the reference image. It does **not** mean the object is genuinely new.

`BRIGHTENED_CANDIDATE` means a matched source's approximate measured flux increased by the configured ratio. Different exposure times, filters, seeing, image registration, or calibration can cause false candidates.

## Suggested next milestones

1. Add astrometric registration for images with different pixel grids.
2. Use robust image subtraction and PSF matching (for example, a dedicated difference-imaging package).
3. Cross-match candidate sky coordinates with catalogs.
4. Add light-curve history and a database.
5. Add a public transient-alert adapter such as Lasair, after checking its current API and access requirements.
6. Evaluate against historical, labeled transient observations and report precision/recall.

## Project structure

```text
src/nova/
  __init__.py
  cli.py          # Typer commands
  fits_utils.py   # FITS loading and image metadata
  detection.py    # Background estimation and source detection
  comparison.py   # Pixel-coordinate source matching
  plotting.py     # Diagnostic plots
  demo.py         # Synthetic FITS demo generator
tests/
  test_core.py
```

## Citation / provenance

When testing on public data, record the archive, observation identifier, instrument, filter, observation time, calibration level, and original download URL in your notes. Preserve the original files and do not treat an automated candidate report as a confirmed astronomical discovery.
