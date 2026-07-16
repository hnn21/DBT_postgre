import datetime

import pytest

from load_raw import resolve_mode

TODAY = datetime.date(2026, 7, 16)


def test_full_when_no_args():
    assert resolve_mode(None, None, None, TODAY) == ("full", None, None)


def test_days_window_from_today():
    assert resolve_mode(None, None, 7, TODAY) == (
        "range", datetime.date(2026, 7, 9), datetime.date(2026, 7, 16))


def test_explicit_range():
    assert resolve_mode("2026-07-01", "2026-07-14", None, TODAY) == (
        "range", datetime.date(2026, 7, 1), datetime.date(2026, 7, 14))


def test_days_with_range_rejected():
    with pytest.raises(ValueError):
        resolve_mode("2026-07-01", "2026-07-14", 7, TODAY)


def test_from_without_to_rejected():
    with pytest.raises(ValueError):
        resolve_mode("2026-07-01", None, None, TODAY)


def test_to_without_from_rejected():
    with pytest.raises(ValueError):
        resolve_mode(None, "2026-07-14", None, TODAY)


def test_from_after_to_rejected():
    with pytest.raises(ValueError):
        resolve_mode("2026-07-14", "2026-07-01", None, TODAY)


def test_days_non_positive_rejected():
    with pytest.raises(ValueError):
        resolve_mode(None, None, 0, TODAY)
