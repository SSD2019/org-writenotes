#!/usr/bin/env python3
"""Recognize handwriting in a Write .svgz sketch with TrOCR.

Reads a gzipped (or plain) SVG from stdin, strips the page template (paper,
ruling, margins, background images) and highlighter strokes, renders what is
left to a white-background PNG, splits it into text lines by ink projection,
and runs TrOCR line by line.
Prints one JSON object to stdout: {"lines": [...], "engine": ..., "device": ...}.

Usage:
    recognize.py [--model ID] [--device auto|cuda|cpu] < sketch.svgz
"""

import argparse
import gzip
import io
import json
import sys
import xml.etree.ElementTree as ET

import cairosvg
import numpy as np
import torch
from PIL import Image
from transformers import TrOCRProcessor, VisionEncoderDecoderModel

DEFAULT_MODEL = "microsoft/trocr-base-handwritten"
RENDER_WIDTH = 1654  # roughly A5-at-150dpi; keeps stroke thickness readable
INK_THRESHOLD = 200  # grayscale value below which a pixel counts as ink
MIN_GAP_ROWS = 12  # blank rows that separate two text lines
MIN_LINE_ROWS = 8  # ignore ink bands thinner than this (dots, noise)
PAD = 16
HIGHLIGHTER_MAX_OPACITY = 0.6  # wide strokes more transparent than this are highlighter
HIGHLIGHTER_MIN_WIDTH = 10.0

SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")


def read_svg(raw: bytes) -> str:
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return raw.decode("utf-8")


def _tag(el) -> str:
    return el.tag.rsplit("}", 1)[-1]


def _is_template(el) -> bool:
    """Paper, ruling/grid/dots, margins, the document backdrop and background images."""
    classes = (el.get("class") or "").split()
    return (
        "ruleline" in classes
        or "pagerect" in classes
        or el.get("id") == "write-doc-background"
        or _tag(el) == "image"
    )


def _is_highlighter(el) -> bool:
    if _tag(el) != "path":
        return False
    try:
        opacity = float(el.get("stroke-opacity", "1"))
        width = float(el.get("stroke-width", "0"))
    except ValueError:
        return False
    return opacity < HIGHLIGHTER_MAX_OPACITY and width >= HIGHLIGHTER_MIN_WIDTH


def _prune(el) -> None:
    for child in list(el):
        if _is_template(child) or _is_highlighter(child):
            el.remove(child)
        else:
            _prune(child)


def _length(value: str | None) -> float | None:
    try:
        return float((value or "").removesuffix("px"))
    except ValueError:
        return None


def strip_template(svg_text: str) -> str:
    """Return the SVG with only the user's pen strokes, cropped to the page.

    The page template would otherwise be rendered as ink: dotted or grid ruling
    is dark enough to make every row of the image look written on.
    """
    root = ET.fromstring(svg_text)
    _prune(root)

    # The document root has no size of its own; frame it on the page so the
    # grey backdrop around the page falls outside the render.
    page = next((el for el in root.iter() if "write-page" in (el.get("class") or "").split()), None)
    if page is not None:
        x, y = _length(page.get("x")) or 0.0, _length(page.get("y")) or 0.0
        w, h = _length(page.get("width")), _length(page.get("height"))
        if w and h:
            root.set("width", f"{w}px")
            root.set("height", f"{h}px")
            root.set("viewBox", f"{x} {y} {w} {h}")
    return ET.tostring(root, encoding="unicode")


def render_png(svg_text: str) -> Image.Image:
    png = cairosvg.svg2png(
        bytestring=strip_template(svg_text).encode("utf-8"),
        output_width=RENDER_WIDTH,
        background_color="white",
    )
    return Image.open(io.BytesIO(png)).convert("L")


def split_lines(page: Image.Image) -> list[Image.Image]:
    """Cut a grayscale page into tight text-line crops."""
    ink = np.asarray(page) < INK_THRESHOLD
    row_has_ink = ink.any(axis=1)

    bands = []
    start = None
    blank_run = 0
    for y, has in enumerate(row_has_ink):
        if has:
            if start is None:
                start = y
            blank_run = 0
        elif start is not None:
            blank_run += 1
            if blank_run >= MIN_GAP_ROWS:
                bands.append((start, y - blank_run + 1))
                start = None
                blank_run = 0
    if start is not None:
        bands.append((start, len(row_has_ink)))

    crops = []
    for top, bottom in bands:
        if bottom - top < MIN_LINE_ROWS:
            continue
        cols = np.flatnonzero(ink[top:bottom].any(axis=0))
        left = max(0, int(cols[0]) - PAD)
        right = min(page.width, int(cols[-1]) + 1 + PAD)
        box = (left, max(0, top - PAD), right, min(page.height, bottom + PAD))
        # TrOCR expects RGB; a single channel is replicated by the processor.
        crops.append(page.crop(box).convert("RGB"))
    return crops


def pick_device(requested: str) -> str:
    if requested == "auto":
        return "cuda" if torch.cuda.is_available() else "cpu"
    if requested == "cuda" and not torch.cuda.is_available():
        raise SystemExit("--device cuda requested but no CUDA device is available")
    return requested


def recognize_lines(crops, model_id: str, device: str) -> list[str]:
    processor = TrOCRProcessor.from_pretrained(model_id)
    model = VisionEncoderDecoderModel.from_pretrained(model_id).to(device)
    model.eval()

    texts = []
    with torch.inference_mode():
        for crop in crops:
            pixel_values = processor(images=crop, return_tensors="pt").pixel_values.to(device)
            ids = model.generate(pixel_values, max_new_tokens=96)
            text = processor.batch_decode(ids, skip_special_tokens=True)[0].strip()
            if text:
                texts.append(text)
    return texts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    args = parser.parse_args()

    svg_text = read_svg(sys.stdin.buffer.read())
    page = render_png(svg_text)
    crops = split_lines(page)
    device = pick_device(args.device)
    lines = recognize_lines(crops, args.model, device) if crops else []

    json.dump(
        {"lines": lines, "engine": f"trocr:{args.model}", "device": device},
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
