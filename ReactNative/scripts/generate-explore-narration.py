#!/usr/bin/env python3
"""Author approved Explore clips; never run as part of an app build.

Contract: https://openrouter.ai/docs/api/api-reference/tts/create-speech
Response validation: https://openrouter.ai/blog/tutorials/text-to-speech/
Only the manifest and .caf files belong in the app; sources/ retains the
lossless PCM capture and a FLAC master for the separate listening/provenance
review. No generation happens on import.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

BASE = "https://openrouter.ai/api/v1"
PCM_RATE = 24000
PCM_CHANNELS = 1
OPUS_BITRATE = "30k"
MAX_AUDIO = 16 * 1024 * 1024
MAX_JSON = 4 * 1024 * 1024
SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z")


class GenerationError(Exception):
    """A deliberately safe operator message, without provider bodies or credentials."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GenerationError("Unexpected HTTP redirect; no credentials were forwarded.")


def http_request(url, payload, api_key, limit):
    """Bounded, no-redirect transport; failures never print request headers or bodies."""
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers={
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
        "Accept": "application/json" if payload is None else "audio/pcm",
    })
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=60) as response:
            if not 200 <= response.status < 300:
                raise GenerationError("Provider returned a non-success HTTP status.")
            headers = {key.lower(): value for key, value in response.headers.items()}
            try:
                if int(headers.get("content-length", "0")) > limit:
                    raise GenerationError("Provider response exceeds the size limit.")
            except ValueError:
                raise GenerationError("Invalid provider content length.") from None
            chunks, size = [], 0
            while True:
                chunk = response.read(min(64 * 1024, limit + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > limit:
                    raise GenerationError("Provider response exceeds the size limit.")
            return headers, b"".join(chunks)
    except urllib.error.HTTPError as error:
        raise GenerationError(f"Provider HTTP failure ({error.code}); no error body was saved.") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise GenerationError("Provider connection failed or timed out.") from None


def parse_json(data, message):
    try:
        return json.loads(data)
    except (ValueError, UnicodeDecodeError):
        raise GenerationError(message) from None


def declared_pcm_format(content_type):
    """Rate/channels the provider declared, or None when it declared neither."""
    rate = channels = None
    for part in content_type.split(";")[1:]:
        key, _, value = part.partition("=")
        key, value = key.strip().lower(), value.strip()
        if key == "rate":
            rate = int(value) if value.isdecimal() else -1
        elif key == "channels":
            channels = int(value) if value.isdecimal() else -1
    return rate, channels


def validate_script(script, model, voice, revision):
    if not isinstance(script, dict) or script.get("schema") != 1 or script.get("approved") is not True:
        raise GenerationError("The script and all translations require explicit approval before generation.")
    if isinstance(script.get("metadata"), dict) and script["metadata"].get("audioGenerationApproved") is False:
        raise GenerationError("The script still explicitly withholds audio generation approval.")
    approved_revision = script.get("revision")
    if not all(isinstance(item, str) and 0 < len(item) <= 200 for item in (model, voice, revision, approved_revision)):
        raise GenerationError("Explicit model, voice and authoring revision are required.")
    if script.get("model") != model or script.get("voice") != voice or approved_revision != revision:
        raise GenerationError("Model, voice and authoring revision must match the approved script.")
    scenes = script.get("scenes")
    if not isinstance(scenes, list) or not 1 <= len(scenes) <= 100:
        raise GenerationError("The script requires a bounded scene list.")
    overrides = script.get("voices", {})
    if not isinstance(overrides, dict):
        raise GenerationError("Per-locale voices must be a mapping when present.")
    seen, expected_locales, clips = set(), None, []
    for scene in scenes:
        if not isinstance(scene, dict):
            raise GenerationError("Invalid scene.")
        scene_id, locales = scene.get("id"), scene.get("locales")
        if not isinstance(scene_id, str) or not SAFE_ID.fullmatch(scene_id) or scene_id in seen:
            raise GenerationError("Scene IDs must be unique, safe filename components.")
        if not isinstance(locales, dict) or not 1 <= len(locales) <= 20:
            raise GenerationError("Each scene requires approved localized text.")
        if expected_locales is None:
            expected_locales = set(locales)
        if set(locales) != expected_locales:
            raise GenerationError("Every scene must contain the same approved locale set.")
        seen.add(scene_id)
        for locale, text in sorted(locales.items()):
            if not isinstance(locale, str) or not SAFE_ID.fullmatch(locale):
                raise GenerationError("Locale must be a safe filename component.")
            if not isinstance(text, str) or not text.strip() or len(text) > 2000:
                raise GenerationError("Narration text must be nonempty and at most 2000 characters.")
            override = overrides.get(locale, {})
            if not isinstance(override, dict):
                raise GenerationError("Locale voice overrides must be mappings.")
            clip_model = override.get("model", model)
            clip_voice = override.get("voice", voice)
            if not all(isinstance(item, str) and 0 < len(item) <= 200 for item in (clip_model, clip_voice)):
                raise GenerationError("A locale voice override requires a model and voice.")
            clips.append((scene_id, locale, text, clip_model, clip_voice))
    # Every override locale must belong to the approved locale set.
    if expected_locales is not None and any(locale not in expected_locales for locale in overrides):
        raise GenerationError("Per-locale voices may only name approved locales.")
    return clips


def verify_model(model, api_key, request):
    headers, data = request(BASE + "/models?output_modalities=speech", None, api_key, MAX_JSON)
    if headers.get("content-type", "").split(";")[0].strip() != "application/json" or len(data) > MAX_JSON:
        raise GenerationError("Invalid Models API response.")
    catalog = parse_json(data, "Models API returned invalid JSON.")
    models = catalog.get("data") if isinstance(catalog, dict) else None
    if not isinstance(models, list):
        raise GenerationError("Models API omitted its model list.")
    record = next((item for item in models if isinstance(item, dict) and item.get("id") == model), None)
    if record is None:
        raise GenerationError("The approved model is absent from the current speech catalog.")
    # This is observed routing provenance, not a promise of immutable provider weights.
    return {key: record[key] for key in ("id", "canonical_slug", "created") if key in record}


def render_audio(source, target, master=None, run=subprocess.run):
    environment = {key: value for key, value in os.environ.items() if key != "OPENROUTER_API_KEY"}
    try:
        if master is not None:
            run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "s16le",
                 "-ar", str(PCM_RATE), "-ac", str(PCM_CHANNELS), "-i", str(source),
                 "-map_metadata", "-1", "-c:a", "flac", str(master)],
                check=True, capture_output=True, timeout=90, env=environment)
        run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "s16le",
             "-ar", str(PCM_RATE), "-ac", str(PCM_CHANNELS), "-i", str(source),
             "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "48000", "-c:a", "libopus",
             "-b:a", OPUS_BITRATE, "-vbr", "on", "-application", "voip",
             "-map_metadata", "-1", "-f", "caf", str(target)],
            check=True, capture_output=True, timeout=90, env=environment)
        result = run(["ffprobe", "-v", "error", "-show_entries",
                      "format=format_name,duration:stream=codec_name,channels",
                      "-of", "json", str(target)], check=True, capture_output=True, timeout=15, env=environment)
    except (subprocess.SubprocessError, OSError):
        raise GenerationError("Local audio conversion or inspection failed.") from None
    probe = parse_json(result.stdout, "ffprobe returned invalid JSON.")
    try:
        duration = float(probe["format"]["duration"])
        streams = probe["streams"]
        valid_stream = len(streams) == 1 and streams[0]["codec_name"] == "opus" and streams[0]["channels"] == 1
        valid_format = "caf" in probe["format"]["format_name"]
        valid_size = 0 < target.stat().st_size <= MAX_AUDIO
    except (KeyError, TypeError, ValueError, OSError):
        raise GenerationError("Converted audio metadata is invalid.") from None
    if not valid_stream or not valid_format or not valid_size or not math.isfinite(duration) or not 0 < duration <= 30:
        raise GenerationError("Converted audio must be mono Opus in CAF, nonempty, and no longer than 30 seconds.")
    return duration


def generate(script_path, output, model, voice, revision, *, api_key=None,
             request=http_request, convert=render_audio):
    script_path, output = Path(script_path), Path(output)
    if script_path.stat().st_size > MAX_JSON:
        raise GenerationError("Script exceeds the size limit.")
    script_bytes = script_path.read_bytes()
    script = parse_json(script_bytes, "Script is not valid JSON.")
    scenes = validate_script(script, model, voice, revision)
    api_key = os.environ.get("OPENROUTER_API_KEY", "") if api_key is None else api_key
    if not api_key or not api_key.strip():
        raise GenerationError("OPENROUTER_API_KEY is required; set it in the local environment.")
    if output.exists() or output.is_symlink():
        raise GenerationError("Output must be a new directory; existing packs are never replaced.")
    if not output.parent.is_dir():
        raise GenerationError("Output parent directory must already exist.")
    observed_models = {}
    for distinct in dict.fromkeys((clip[3] for clip in scenes)):
        observed_models[distinct] = verify_model(distinct, api_key, request)
    stage = Path(tempfile.mkdtemp(prefix=".explore-narration-", dir=output.parent))
    reserved_output = False
    try:
        (stage / "sources").mkdir()
        clips = []
        for scene_id, locale, text, clip_model, clip_voice in scenes:
            headers, audio = request(BASE + "/audio/speech", {
                "model": clip_model, "voice": clip_voice, "input": text, "response_format": "pcm",
            }, api_key, MAX_AUDIO)
            if headers.get("content-type", "").split(";")[0].strip() != "audio/pcm":
                raise GenerationError("Provider returned a non-PCM response; no audio was published.")
            rate, channels = declared_pcm_format(headers.get("content-type", ""))
            if rate not in (None, PCM_RATE) or channels not in (None, PCM_CHANNELS):
                raise GenerationError("Provider PCM format differs from the packed format; refusing to resample silently.")
            if not audio or len(audio) > MAX_AUDIO or len(audio) % (2 * PCM_CHANNELS) != 0:
                raise GenerationError("Provider audio is empty, misaligned or exceeds the size limit.")
            stem = f"{scene_id}.{locale}"
            source = stage / "sources" / f"{stem}.pcm"
            master = stage / "sources" / f"{stem}.flac"
            filename = f"{stem}.caf"
            target = stage / filename
            source.write_bytes(audio)
            duration = convert(source, target, master)
            generation_id = headers.get("x-generation-id")
            if not isinstance(generation_id, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", generation_id):
                generation_id = None
            clips.append({"approved": True, "text": text, "locale": locale, "file": filename,
                "codec": "opus", "container": "caf", "bitrate": OPUS_BITRATE,
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "durationSeconds": duration,
                "sceneID": scene_id, "model": clip_model, "voice": clip_voice, "revision": revision,
                "generationID": generation_id})
        manifest = {"schemaVersion": 1, "clips": clips, "scriptSHA256": hashlib.sha256(script_bytes).hexdigest(),
                    "observedModels": observed_models, "listeningQualified": False}
        (stage / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        # Same-volume directory rename publishes the complete pack in one step. A
        # failed generation leaves no runtime manifest or partly approved output.
        # Reserve exclusively at publication too, closing the generation-time race
        # with another authoring process choosing this output directory.
        output.mkdir()
        reserved_output = True
        stage.rename(output)
        reserved_output = False
        return manifest
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        if reserved_output:
            try:
                output.rmdir()
            except OSError:
                pass  # Preserve anything another process placed in the reserved directory.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--voice", required=True)
    parser.add_argument("--revision", required=True, help="Approved authoring revision; provider weights are separately observed.")
    args = parser.parse_args()
    try:
        manifest = generate(args.script, args.output, args.model, args.voice, args.revision)
    except (GenerationError, OSError) as error:
        # Never expose subprocess/HTTP exception strings, provider JSON or credentials.
        print(str(error) if isinstance(error, GenerationError) else "Could not read or publish narration files.", file=sys.stderr)
        return 1
    print(f"Generated {len(manifest['clips'])} clips. Listening qualification remains required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
