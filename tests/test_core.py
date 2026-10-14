import numpy as np
import pytest

from nova.comparison import compare_images
from nova.demo import _make_field
from nova.detection import detect_sources


def test_detect_sources_finds_synthetic_points():
    image = _make_field(seed=1, include_transient=True)
    sources, metadata = detect_sources(image, threshold_sigma=5.0)
    assert metadata["count"] >= 5
    assert all("x" in source and "y" in source and "flux" in source for source in sources)


def test_compare_flags_added_source():
    reference = _make_field(seed=1, include_transient=False)
    new_image = _make_field(seed=2, include_transient=True)
    candidates, metadata = compare_images(reference, new_image, threshold_sigma=5.0)
    assert metadata["candidate_count"] >= 1
    assert any(candidate["status"] == "NEW_CANDIDATE" for candidate in candidates)


def test_compare_rejects_mismatched_shapes():
    with pytest.raises(ValueError, match="shapes differ"):
        compare_images(np.zeros((32, 32)), np.zeros((40, 40)))


def test_invalid_threshold_rejected():
    with pytest.raises(ValueError):
        detect_sources(np.ones((32, 32)), threshold_sigma=0)
