from __future__ import annotations

import argparse
from contextlib import asynccontextmanager
import importlib.util
import logging
import os
import threading
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

LOGGER = logging.getLogger("lingosnap.backend")
ROOT = Path(__file__).resolve().parent
TRANSLATION_MODEL_DIR = ROOT / "models" / "argos-en-vi"
CT2_MODEL_DIR = TRANSLATION_MODEL_DIR / "model"
TOKENIZER_PATH = TRANSLATION_MODEL_DIR / "sentencepiece.model"
OCR_MODEL_DIR = ROOT / "models" / "rapidocr"
OCR_DET_MODEL_PATH = OCR_MODEL_DIR / "ch_PP-OCRv5_det_mobile.onnx"
OCR_CLS_MODEL_PATH = OCR_MODEL_DIR / "ch_ppocr_mobile_v2.0_cls_mobile.onnx"
OCR_REC_MODEL_PATH = OCR_MODEL_DIR / "en_PP-OCRv5_rec_mobile.onnx"
LANGUAGE_TOOL_DIR = ROOT / "models" / "languagetool"
LANGUAGE_TOOL_VERSION = "6.8"
LANGUAGE_TOOL_JAR_PATH = (
    LANGUAGE_TOOL_DIR / f"LanguageTool-{LANGUAGE_TOOL_VERSION}" / "languagetool-server.jar"
)
os.environ["LTP_PATH"] = str(LANGUAGE_TOOL_DIR)


class AnalyzeRequest(BaseModel):
    image_path: str = Field(alias="imagePath")
    source_language: str = Field(alias="sourceLanguage")
    target_language: str = Field(alias="targetLanguage")


class TranslateRequest(BaseModel):
    text: str
    source_language: str = Field(alias="sourceLanguage")
    target_language: str = Field(alias="targetLanguage")


class GrammarRequest(BaseModel):
    text: str
    language: str = "en-US"


class LocalEngines:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._ocr: Any = None
        self._translator: Any = None
        self._source_sp: Any = None
        self._grammar: Any = None
        self._grammar_lock = threading.Lock()
        self._error: str | None = None

    @property
    def ready(self) -> bool:
        return self._ocr is not None and self._translator is not None

    @property
    def translation_ready(self) -> bool:
        return self._translator is not None and self._source_sp is not None

    @property
    def grammar_ready(self) -> bool:
        return self._grammar is not None

    @property
    def error(self) -> str | None:
        return self._error

    def ensure_ready(self) -> None:
        self.ensure_translation_ready()
        if self._ocr is not None:
            return
        with self._lock:
            if self._ocr is not None:
                return
            try:
                self._load_ocr()
                self._error = None
            except Exception as error:
                self._error = str(error)
                raise

    def ensure_translation_ready(self) -> None:
        if self.translation_ready:
            return
        with self._lock:
            if self.translation_ready:
                return
            try:
                self._load_translation()
                self._error = None
            except Exception as error:
                self._error = str(error)
                raise

    def ensure_grammar_ready(self) -> None:
        if self.grammar_ready:
            return
        with self._grammar_lock:
            if self.grammar_ready:
                return
            try:
                self._load_grammar()
                self._error = None
            except Exception as error:
                self._error = str(error)
                raise

    def _load_translation(self) -> None:
        missing = [
            name
            for name in ("ctranslate2", "sentencepiece")
            if importlib.util.find_spec(name) is None
        ]
        if missing:
            raise RuntimeError(
                "Thiếu package Python: "
                + ", ".join(missing)
                + ". Hãy chạy backend\\setup_backend.ps1."
            )
        if not (CT2_MODEL_DIR / "model.bin").is_file():
            raise RuntimeError(
                "Chưa có model dịch English→Vietnamese. "
                "Hãy chạy backend\\setup_backend.ps1."
            )
        if not TOKENIZER_PATH.is_file():
            raise RuntimeError("Thiếu sentencepiece.model của model dịch.")

        import ctranslate2
        import sentencepiece as sentencepiece

        self._source_sp = sentencepiece.SentencePieceProcessor(
            model_file=str(TOKENIZER_PATH)
        )
        self._translator = ctranslate2.Translator(
            str(CT2_MODEL_DIR),
            device="cpu",
            compute_type="int8",
            inter_threads=1,
        )

    def _load_ocr(self) -> None:
        missing = [
            name
            for name in ("rapidocr", "onnxruntime")
            if importlib.util.find_spec(name) is None
        ]
        if missing:
            raise RuntimeError(
                "Thiếu package Python: "
                + ", ".join(missing)
                + ". Hãy chạy backend\\setup_backend.ps1."
            )
        missing_models = [
            path.name
            for path in (
                OCR_DET_MODEL_PATH,
                OCR_CLS_MODEL_PATH,
                OCR_REC_MODEL_PATH,
            )
            if not path.is_file()
        ]
        if missing_models:
            raise RuntimeError(
                "Thiếu model OCR ONNX: "
                + ", ".join(missing_models)
                + ". Hãy chạy backend\\setup_backend.ps1."
            )

        from rapidocr import (
            EngineType,
            LangCls,
            LangDet,
            LangRec,
            ModelType,
            OCRVersion,
            RapidOCR,
        )

        self._ocr = RapidOCR(
            params={
                "Global.log_level": "warning",
                "Global.model_root_dir": str(OCR_MODEL_DIR),
                "Global.use_cls": False,
                "Global.use_vertical_padding": False,
                "Det.engine_type": EngineType.ONNXRUNTIME,
                "Det.lang_type": LangDet.CH,
                "Det.model_type": ModelType.MOBILE,
                "Det.ocr_version": OCRVersion.PPOCRV5,
                "Det.model_path": str(OCR_DET_MODEL_PATH),
                "Det.limit_type": "max",
                "Det.limit_side_len": 960,
                "Cls.engine_type": EngineType.ONNXRUNTIME,
                "Cls.lang_type": LangCls.CH,
                "Cls.model_type": ModelType.MOBILE,
                "Cls.ocr_version": OCRVersion.PPOCRV4,
                "Cls.model_path": str(OCR_CLS_MODEL_PATH),
                "Rec.engine_type": EngineType.ONNXRUNTIME,
                "Rec.lang_type": LangRec.EN,
                "Rec.model_type": ModelType.MOBILE,
                "Rec.ocr_version": OCRVersion.PPOCRV5,
                "Rec.model_path": str(OCR_REC_MODEL_PATH),
            }
        )

    def _load_grammar(self) -> None:
        if importlib.util.find_spec("language_tool_python") is None:
            raise RuntimeError(
                "Thiếu package Python language_tool_python. "
                "Hãy chạy backend\\setup_backend.ps1."
            )

        LANGUAGE_TOOL_DIR.mkdir(parents=True, exist_ok=True)
        try:
            import language_tool_python

            self._grammar = language_tool_python.LanguageTool(
                "en-US",
                language_tool_download_version=LANGUAGE_TOOL_VERSION,
            )
        except Exception as error:
            raise RuntimeError(
                "Không khởi động được LanguageTool local. "
                "Cần Java 17 và model LanguageTool đã được cài bằng "
                f"backend\\setup_backend.ps1. Chi tiết: {error}"
            ) from error

    def analyze(self, image_path: Path) -> dict[str, Any]:
        self.ensure_ready()
        result = self._ocr(str(image_path), use_cls=False)
        if len(result) == 0:
            return {"items": []}

        entries = _extract_ocr_entries(result)
        if not entries:
            return {"items": []}

        original = "\n".join(entry[0] for entry in entries)
        average_confidence = sum(entry[1] for entry in entries) / len(entries)
        box = _union_boxes([entry[2] for entry in entries])
        translated = self.translate(original, ensure_ready=False)

        return {
            "items": [
                {
                    "original": original,
                    "translated": translated,
                    "confidence": average_confidence,
                    "box": box,
                }
            ]
        }

    def translate(self, text: str, *, ensure_ready: bool = True) -> str:
        if ensure_ready:
            self.ensure_translation_ready()
        source_text = " ".join(text.splitlines()).strip()
        if not source_text:
            return ""
        source_tokens = self._source_sp.encode(source_text, out_type=str)
        translation = self._translator.translate_batch(
            [source_tokens],
            beam_size=2,
            max_decoding_length=512,
        )[0]
        return (
            "".join(translation.hypotheses[0]).replace(chr(0x2581), " ").strip()
        )

    def check_grammar(self, text: str, language: str) -> dict[str, Any]:
        if language != "en-US":
            raise ValueError("Kiểm tra ngữ pháp hiện chỉ hỗ trợ English (US).")
        self.ensure_grammar_ready()
        from language_tool_python.utils import correct

        with self._grammar_lock:
            matches = self._grammar.check(text)
        corrected = correct(text, matches)
        return {
            "corrected": corrected,
            "issueCount": sum(1 for match in matches if match.replacements),
        }

    def close(self) -> None:
        grammar = self._grammar
        self._grammar = None
        if grammar is not None:
            grammar.close()


def _extract_ocr_entries(result: Any) -> list[tuple[str, float, list[float]]]:
    texts = result.txts if result.txts is not None else ()
    scores = result.scores if result.scores is not None else ()
    boxes = result.boxes if result.boxes is not None else ()
    entries: list[tuple[str, float, list[float]]] = []
    for index, raw_text in enumerate(texts):
        text = str(raw_text).strip()
        score = float(scores[index]) if index < len(scores) else 0.0
        if not text or score < 0.30:
            continue
        raw_points = boxes[index] if index < len(boxes) else ()
        points = [
            (float(point[0]), float(point[1]))
            for point in raw_points
            if len(point) >= 2
        ]
        if points:
            box = [
                min(point[0] for point in points),
                min(point[1] for point in points),
                max(point[0] for point in points),
                max(point[1] for point in points),
            ]
        else:
            box = [0.0, 0.0, 0.0, 0.0]
        entries.append((text, score, box))

    entries.sort(key=lambda entry: (entry[2][1], entry[2][0]))
    return entries


def _union_boxes(boxes: list[list[float]]) -> list[float]:
    if not boxes:
        return [0.0, 0.0, 0.0, 0.0]
    return [
        min(box[0] for box in boxes),
        min(box[1] for box in boxes),
        max(box[2] for box in boxes),
        max(box[3] for box in boxes),
    ]


engines = LocalEngines()


@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        yield
    finally:
        engines.close()


app = FastAPI(
    title="LingoSnap local backend",
    version="0.2.0",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict[str, Any]:
    packages_ready = all(
        importlib.util.find_spec(name) is not None
        for name in (
            "rapidocr",
            "onnxruntime",
            "ctranslate2",
            "sentencepiece",
            "language_tool_python",
        )
    )
    models_ready = all(
        path.is_file()
        for path in (
            CT2_MODEL_DIR / "model.bin",
            TOKENIZER_PATH,
            OCR_DET_MODEL_PATH,
            OCR_CLS_MODEL_PATH,
            OCR_REC_MODEL_PATH,
            LANGUAGE_TOOL_JAR_PATH,
        )
    )
    return {
        "ok": True,
        "ready": engines.ready,
        "grammarReady": engines.grammar_ready,
        "packagesReady": packages_ready,
        "modelsReady": models_ready,
        "error": engines.error,
    }


@app.post("/analyze")
def analyze(request: AnalyzeRequest) -> dict[str, Any]:
    image_path = Path(request.image_path).expanduser().resolve()
    if request.source_language != "en" or request.target_language != "vi":
        raise HTTPException(status_code=400, detail="MVP chỉ hỗ trợ English → Vietnamese.")
    if not image_path.is_file():
        raise HTTPException(status_code=400, detail=f"Không tìm thấy ảnh: {image_path}")
    try:
        return engines.analyze(image_path)
    except HTTPException:
        raise
    except Exception as error:
        LOGGER.exception("Analyze failed")
        raise HTTPException(status_code=503, detail=str(error)) from error


@app.post("/translate")
def translate(request: TranslateRequest) -> dict[str, str]:
    if request.source_language != "en" or request.target_language != "vi":
        raise HTTPException(status_code=400, detail="MVP chỉ hỗ trợ English → Vietnamese.")
    text = request.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Hãy nhập văn bản tiếng Anh cần dịch.")
    try:
        return {"translated": engines.translate(text)}
    except Exception as error:
        LOGGER.exception("Translate failed")
        raise HTTPException(status_code=503, detail=str(error)) from error


@app.post("/grammar")
def grammar(request: GrammarRequest) -> dict[str, Any]:
    text = request.text.strip()
    if not text:
        raise HTTPException(
            status_code=400,
            detail="Hãy nhập hoặc dán văn bản tiếng Anh cần kiểm tra.",
        )
    if request.language != "en-US":
        raise HTTPException(
            status_code=400,
            detail="Kiểm tra ngữ pháp hiện chỉ hỗ trợ English (US).",
        )
    try:
        return engines.check_grammar(text, request.language)
    except Exception as error:
        LOGGER.exception("Grammar check failed")
        raise HTTPException(status_code=503, detail=str(error)) from error


@app.post("/grammar/warmup")
def grammar_warmup() -> dict[str, bool]:
    try:
        engines.check_grammar("LanguageTool is ready.", "en-US")
        return {"ready": True}
    except Exception as error:
        LOGGER.exception("Grammar warm-up failed")
        raise HTTPException(status_code=503, detail=str(error)) from error


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8765, type=int)
    args = parser.parse_args()

    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
