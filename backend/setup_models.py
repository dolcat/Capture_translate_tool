from __future__ import annotations

import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

import requests

ARGOS_MODEL_URL = "https://argos-net.com/v1/translate-en_vi-1_9.argosmodel"
ROOT = Path(__file__).resolve().parent
MODELS_DIR = ROOT / "models"
ARCHIVE_PATH = MODELS_DIR / "translate-en_vi-1_9.argosmodel"
TRANSLATION_DIR = MODELS_DIR / "argos-en-vi"
CT2_DIR = TRANSLATION_DIR / "model"
OCR_DIR = MODELS_DIR / "rapidocr"
OCR_DET_PATH = OCR_DIR / "ch_PP-OCRv5_det_mobile.onnx"
OCR_CLS_PATH = OCR_DIR / "ch_ppocr_mobile_v2.0_cls_mobile.onnx"
OCR_REC_PATH = OCR_DIR / "en_PP-OCRv5_rec_mobile.onnx"


def _download(url: str, destination: Path) -> None:
    print(f"Downloading {url}")
    with requests.get(url, stream=True, timeout=180) as response:
        response.raise_for_status()
        with destination.open("wb") as output:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    output.write(chunk)


def _safe_extract(archive: Path, destination: Path) -> None:
    destination_resolved = destination.resolve()
    with zipfile.ZipFile(archive) as zip_file:
        for member in zip_file.infolist():
            target = (destination / member.filename).resolve()
            if destination_resolved not in target.parents and target != destination_resolved:
                raise RuntimeError(f"Unsafe archive path: {member.filename}")
        zip_file.extractall(destination)


def prepare_translation_model() -> None:
    import ctranslate2

    tokenizer = TRANSLATION_DIR / "sentencepiece.model"
    if ctranslate2.contains_model(str(CT2_DIR)) and tokenizer.is_file():
        print(f"Translation model is ready: {TRANSLATION_DIR}")
        return

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE_PATH.is_file():
        _download(ARGOS_MODEL_URL, ARCHIVE_PATH)

    with tempfile.TemporaryDirectory(prefix="lingosnap-argos-") as temp_name:
        extracted = Path(temp_name)
        _safe_extract(ARCHIVE_PATH, extracted)
        package_root = extracted / "translate-en_vi-1_9"
        if not package_root.is_dir():
            raise RuntimeError("Argos package does not contain translate-en_vi-1_9")
        if TRANSLATION_DIR.exists():
            shutil.rmtree(TRANSLATION_DIR)
        shutil.copytree(package_root, TRANSLATION_DIR)
    ARCHIVE_PATH.unlink(missing_ok=True)

    if not ctranslate2.contains_model(str(CT2_DIR)) or not tokenizer.is_file():
        raise RuntimeError("Installed Argos English→Vietnamese model is invalid")
    print(f"Translation model is ready: {TRANSLATION_DIR}")


def prepare_ocr_models() -> None:
    print("Preparing RapidOCR PP-OCRv5 ONNX mobile models...")
    from rapidocr import (
        EngineType,
        LangCls,
        LangDet,
        LangRec,
        ModelType,
        OCRVersion,
        RapidOCR,
    )

    OCR_DIR.mkdir(parents=True, exist_ok=True)
    params = {
        "Global.log_level": "warning",
        "Global.model_root_dir": str(OCR_DIR),
        "Global.use_cls": False,
        "Global.use_vertical_padding": False,
        "Det.engine_type": EngineType.ONNXRUNTIME,
        "Det.lang_type": LangDet.CH,
        "Det.model_type": ModelType.MOBILE,
        "Det.ocr_version": OCRVersion.PPOCRV5,
        "Det.limit_type": "max",
        "Det.limit_side_len": 960,
        "Cls.engine_type": EngineType.ONNXRUNTIME,
        "Cls.lang_type": LangCls.CH,
        "Cls.model_type": ModelType.MOBILE,
        "Cls.ocr_version": OCRVersion.PPOCRV4,
        "Rec.engine_type": EngineType.ONNXRUNTIME,
        "Rec.lang_type": LangRec.EN,
        "Rec.model_type": ModelType.MOBILE,
        "Rec.ocr_version": OCRVersion.PPOCRV5,
    }
    RapidOCR(params=params)

    missing = [
        path.name
        for path in (OCR_DET_PATH, OCR_CLS_PATH, OCR_REC_PATH)
        if not path.is_file()
    ]
    if missing:
        raise RuntimeError("Downloaded RapidOCR models are missing: " + ", ".join(missing))
    print(f"RapidOCR ONNX models are ready: {OCR_DIR}")


def main() -> int:
    try:
        prepare_translation_model()
        prepare_ocr_models()
    except Exception as error:
        print(f"Model setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
