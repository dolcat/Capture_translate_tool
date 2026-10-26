"""Converts VinAI Translate en2vi v2 (mBART) to a CTranslate2 INT8 model for the C++ backend.

Run through tool\\convert_vinai.ps1, which prepares the Python environment. Writes
<models>\\vinai-en-vi\\model\\ and <models>\\vinai-en-vi\\sentencepiece.bpe.model.
"""
import argparse
import shutil
from pathlib import Path

import ctranslate2
import sentencepiece as spm
from huggingface_hub import hf_hub_download

REPO = 'vinai/vinai-translate-en2vi-v2'


def translate(model_dir: Path, text: str) -> str:
    sp = spm.SentencePieceProcessor(model_file=str(model_dir / 'sentencepiece.bpe.model'))
    tr = ctranslate2.Translator(str(model_dir / 'model'), compute_type='int8', intra_threads=2)
    # mBART: source is "pieces </s> en_XX" and decoding starts at "vi_VN".
    source = sp.encode(text, out_type=str) + ['</s>', 'en_XX']
    tokens = tr.translate_batch([source], target_prefix=[['vi_VN']], beam_size=2)[0].hypotheses[0]
    return sp.decode([t for t in tokens if t != 'vi_VN'])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('models_dir', type=Path)
    args = parser.parse_args()
    target = args.models_dir / 'vinai-en-vi'
    staging = args.models_dir / 'vinai-en-vi.tmp'
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    print(f'Converting {REPO} (downloads about 1.7 GB the first time)...')
    converter = ctranslate2.converters.TransformersConverter(REPO)
    converter.convert(str(staging / 'model'), quantization='int8', force=True)
    shutil.copy(hf_hub_download(REPO, 'sentencepiece.bpe.model'), staging / 'sentencepiece.bpe.model')

    sample = translate(staging, 'We need to check the budget.')
    print(f'Test: "We need to check the budget." -> "{sample}"')
    words = sample.lower().split()
    if not words or len(set(words)) <= len(words) // 2:
        raise SystemExit('The converted model gives a broken translation; the old model was left in place.')

    if target.exists():
        shutil.rmtree(target)
    staging.rename(target)
    print(f'VinAI model ready: {target}')


if __name__ == '__main__':
    main()
