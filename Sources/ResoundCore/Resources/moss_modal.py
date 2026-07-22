# Modal 部署：MOSS-Transcribe-Diarize 0.9B 推理服务（异步提交+轮询）
#
#   部署:  .venv/bin/modal deploy moss_modal.py
#   提交:  POST <base>-submit.modal.run   multipart: file=<audio> [prompt=..] [max_new_tokens=65536]
#          → {"call_id": "..."}
#   取回:  GET  <base>-result.modal.run?call_id=...
#          → 202 {"status":"running"} | 200 {"text","segments",...} | 500 {"error"}
#   鉴权:  Header Authorization: Bearer <MOSS_API_KEY>（Modal Secret `moss-api-key`）
#
# 权重缓存在 Volume `moss-weights`，首次调用自动从 HF 下载（Modal 云端网络快）。

import fastapi
import modal

MODEL_ID = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
HF_CACHE = "/models/hf"

app = modal.App("moss-transcribe")

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg", "git")
    .pip_install("torch", "torchaudio")
    .pip_install(
        "transformers>=5.0",
        "accelerate",
        "huggingface_hub",
        "fastapi[standard]",
        "python-multipart",
    )
    .pip_install("git+https://github.com/OpenMOSS/MOSS-Transcribe-Diarize.git")
    .env({"HF_HOME": HF_CACHE})
)

vol = modal.Volume.from_name("moss-weights", create_if_missing=True)
api_key_secret = modal.Secret.from_name("moss-api-key")


def _check_auth(request: fastapi.Request):
    import os

    from fastapi import HTTPException

    if request.headers.get("authorization", "") != f"Bearer {os.environ['MOSS_API_KEY']}":
        raise HTTPException(status_code=401, detail="bad token")


@app.cls(
    image=image,
    gpu="L4",
    volumes={"/models": vol},
    scaledown_window=180,
    timeout=3600,
)
class Moss:
    @modal.enter()
    def load(self):
        import pathlib

        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor

        hub = pathlib.Path(f"{HF_CACHE}/hub")
        first_download = not (
            hub.exists() and any(p.name.startswith("models--OpenMOSS-Team") for p in hub.glob("*"))
        )
        self.model = (
            AutoModelForCausalLM.from_pretrained(
                MODEL_ID, trust_remote_code=True, dtype="auto"
            )
            .to(dtype=torch.bfloat16)
            .to("cuda")
            .eval()
        )
        self.processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True)
        if first_download:
            vol.commit()

    @modal.method()
    def run(self, audio: bytes, suffix: str, prompt: str | None, max_new_tokens: int) -> dict:
        import os
        import subprocess
        import tempfile
        import time

        import torch
        from moss_transcribe_diarize import parse_transcript
        from moss_transcribe_diarize.inference_utils import (
            build_transcription_messages,
            generate_transcription,
        )

        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, f"in{suffix}")
            wav = os.path.join(td, "out-16k.wav")
            with open(src, "wb") as f:
                f.write(audio)
            subprocess.run(
                ["ffmpeg", "-y", "-i", src, "-ac", "1", "-ar", "16000", wav],
                check=True,
                capture_output=True,
            )
            probe = subprocess.run(
                ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
                 "-of", "csv=p=0", wav],
                check=True, capture_output=True, text=True,
            )
            duration = float(probe.stdout.strip())

            messages = (
                build_transcription_messages(wav, prompt=prompt)
                if prompt
                else build_transcription_messages(wav)
            )
            t0 = time.time()
            result = generate_transcription(
                self.model,
                self.processor,
                messages,
                max_new_tokens=max_new_tokens,
                do_sample=False,
                device=torch.device("cuda"),
                dtype=torch.bfloat16,
            )
            infer = time.time() - t0

        segments = [
            {"start": s.start, "end": s.end, "speaker": s.speaker, "text": s.text}
            for s in parse_transcript(result["text"])
        ]
        return {
            "text": result["text"],
            "segments": segments,
            "duration_sec": round(duration, 2),
            "infer_sec": round(infer, 2),
        }


@app.function(image=image, secrets=[api_key_secret])
@modal.fastapi_endpoint(method="POST", docs=False)
async def submit(request: fastapi.Request):
    import os

    from fastapi import HTTPException

    _check_auth(request)
    form = await request.form()
    upload = form.get("file")
    if upload is None:
        raise HTTPException(status_code=400, detail="missing file field")
    raw = await upload.read()
    suffix = os.path.splitext(upload.filename or "audio.m4a")[1] or ".m4a"
    prompt = form.get("prompt") or None
    max_new_tokens = int(form.get("max_new_tokens") or 65536)

    call = Moss().run.spawn(raw, suffix, prompt, max_new_tokens)
    return {"call_id": call.object_id}


@app.function(image=image, secrets=[api_key_secret])
@modal.fastapi_endpoint(method="GET", docs=False)
def result(request: fastapi.Request, call_id: str):
    from fastapi.responses import JSONResponse

    _check_auth(request)
    fc = modal.FunctionCall.from_id(call_id)
    try:
        out = fc.get(timeout=5)
    except TimeoutError:
        return JSONResponse({"status": "running"}, status_code=202)
    except Exception as e:
        return JSONResponse({"status": "error", "error": str(e)}, status_code=500)
    return out
