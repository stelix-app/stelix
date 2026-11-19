# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

"""Stelix Studio sidecar: Intermediate and Pro levels with BS-Roformer (mlx-audio-separator).

    stelix_sidecar.py --level intermediate|pro --input <wav> --output <dir> --models <dir/roformer>

Writes JSON lines to stdout, and nothing else:
    {"progress": 0.35, "step": "separating"}
    {"done": true, "files": {"vocals": "<dir>/vocals.wav", ...}}
or {"error": "<code>", "message": "<FailureMessage>", "detail": <name or null>}. The app
chooses the sentences. Exits by itself if stdin closes.

No network: the weights live in --models (installed by ModelStore, checked with SHA-256) and every download is
blocked. The .ckpt files are read by read_ckpt, without PyTorch.
"""

import argparse
import collections
import json
import math
import os
import pickle
import shutil
import sys
import threading
import zipfile

# In the bundle (Contents/Resources/sidecar) the script sits next to site-packages and is launched with
# `python3 -I`, which ignores PYTHONPATH: the folder is added here, before any heavy import.
_BUNDLED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site-packages")
if os.path.isdir(_BUNDLED) and _BUNDLED not in sys.path:
    sys.path.insert(0, _BUNDLED)

SAMPLE_RATE = 44_100
# Below ~1024 frames the library's STFT fails: shorter files are stretched to 1 s.
MIN_FRAMES = SAMPLE_RATE
SW = "BS-Roformer-SW.ckpt"
VOCALS = "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
SW_STEMS = ("vocals", "drums", "bass", "other", "guitar", "piano")
# The names inside the working folders are in English: on Save the app chooses the ones in the language
# of whoever uses Stelix.
FILE_NAMES = {stem: f"{stem}.wav" for stem in ("vocals", "drums", "bass", "other", "piano", "guitar")}


class Failure(Exception):
    """`message` is a StelixCore `FailureMessage`, `detail` a name (never text to show)."""

    def __init__(self, code, message, detail=None):
        super().__init__(message)
        self.code, self.message, self.detail = code, message, detail


class NetworkBlocked(RuntimeError):
    pass


def missing_weights(name):
    return Failure("weights", "missingWeights", name)


# --- protocollo -----------------------------------------------------------------------------------

class Protocol:
    def __init__(self, out):
        self.out = out
        self.last = 0.0

    def send(self, obj):
        self.out.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.out.flush()

    def progress(self, value, step):
        """`step` is a StelixCore `JobStep`."""
        self.last = max(self.last, min(1.0, float(value)))  # never backwards
        self.send({"progress": round(self.last, 4), "step": step})

    def stage(self, lo, hi, step):
        """Callback (step, total) that fills the interval [lo, hi] during inference."""
        job_step = step

        def on_step(step, total):
            if total > 0:
                self.progress(lo + (hi - lo) * min(step, total) / total, job_step)
        return on_step


# # --- .ckpt without torch ----------------------------------------------------------------------------

def _storage_dtypes():
    import numpy as np
    return {"FloatStorage": np.float32, "HalfStorage": np.float16, "DoubleStorage": np.float64,
            "LongStorage": np.int64, "IntStorage": np.int32}


def _check_bounds(storage, offset, size, stride):
    """Offset, size and stride must stay inside the storage: as_strided checks nothing, and a
    purpose-built .ckpt would read memory out of bounds (torch weights_only rejects it)."""
    if not (isinstance(offset, int) and all(isinstance(v, int) for v in (*size, *stride))):
        raise pickle.UnpicklingError("tensor with non-integer offset, size or stride")
    if len(size) != len(stride) or offset < 0 or any(v < 0 for v in (*size, *stride)):
        raise pickle.UnpicklingError("tensor with negative offset, size or stride")
    if any(v == 0 for v in size):
        return
    last = offset + sum((n - 1) * s for n, s in zip(size, stride))
    if last >= len(storage):
        raise pickle.UnpicklingError("tensor outside the storage bounds")


class _Budget:
    """Bytes a checkpoint may still take in memory. Past zero the read fails."""

    def __init__(self, limit):
        self.left = limit

    def spend(self, count):
        self.left -= count
        if self.left < 0:
            raise pickle.UnpicklingError("checkpoint asks for more memory than its file holds")


def _rebuild_tensor(storage, offset, size, stride, budget):
    import numpy as np
    size, stride = tuple(size), tuple(stride)
    _check_bounds(storage, offset, size, stride)
    budget.spend(math.prod(size) * storage.itemsize)
    if len(size) == 0:
        return np.array(storage[offset])
    view = np.lib.stride_tricks.as_strided(storage[offset:], shape=tuple(size),
                                           strides=tuple(s * storage.itemsize for s in stride))
    return np.ascontiguousarray(view)


def read_ckpt(path):
    """The state dict of a PyTorch checkpoint (zip), as numpy arrays.

    Only OrderedDict, _rebuild_tensor_v2 and the numeric storages are accepted: the same perimeter as
    torch.load(weights_only=True), and any other global makes the read fail. Every tensor must stay
    inside its storage (`_check_bounds`).

    The storages together, and the tensors together, may take at most as many bytes as the file
    itself: torch stores them uncompressed, one tensor per storage. Without the two budgets a file of
    a few KB could ask for any amount of memory (stride 0, the same storage viewed again and again,
    a deflated member).
    """
    import numpy as np
    dtypes = _storage_dtypes()
    size = os.path.getsize(path)
    storage_budget, tensor_budget = _Budget(size), _Budget(size)
    blobs = {}

    def rebuild(storage, offset, size, stride, *_):
        return _rebuild_tensor(storage, offset, size, stride, tensor_budget)

    with zipfile.ZipFile(path) as archive:
        pkl = next(n for n in archive.namelist() if n.endswith("data.pkl"))
        prefix = pkl[: -len("data.pkl")]

        class Unpickler(pickle.Unpickler):
            def find_class(self, module, name):
                if (module, name) == ("collections", "OrderedDict"):
                    return collections.OrderedDict
                if (module, name) == ("torch._utils", "_rebuild_tensor_v2"):
                    return rebuild
                if module == "torch" and name in dtypes:
                    return name
                raise pickle.UnpicklingError(f"global not allowed in the checkpoint: {module}.{name}")

            def persistent_load(self, pid):
                kind, storage, key, _location, numel = pid
                if kind != "storage" or storage not in dtypes:
                    raise pickle.UnpicklingError(f"storage not allowed: {pid!r}")
                member = f"{prefix}data/{key}"
                if member not in blobs:
                    # The size comes from the zip directory, before anything is inflated.
                    storage_budget.spend(archive.getinfo(member).file_size)
                    blobs[member] = archive.read(member)
                return np.frombuffer(blobs[member], dtype=dtypes[storage], count=numel)

        storage_budget.spend(archive.getinfo(pkl).file_size)
        with archive.open(pkl) as handle:
            state = Unpickler(handle).load()
    if isinstance(state, dict):
        state = state.get("state_dict", state.get("model", state))
    return state


# # --- real separator ------------------------------------------------------------------------------

def block_network():
    """Every HTTP request and every network connection fails: the sidecar never downloads anything.

    requests is enough for mlx-audio-separator 0.1.20; the sockets cover urllib, http.client and any
    other library."""
    import socket

    import requests

    def refuse(self, method, url, *args, **kwargs):
        raise NetworkBlocked(f"network blocked in the sidecar: {method} {url}")

    def refuse_connect(self, address, *args, **kwargs):
        raise NetworkBlocked(f"network blocked in the sidecar: {address!r}")

    def refuse_create(address, *args, **kwargs):
        raise NetworkBlocked(f"network blocked in the sidecar: {address!r}")

    requests.Session.request = refuse
    socket.socket.connect = refuse_connect
    socket.socket.connect_ex = refuse_connect
    socket.create_connection = refuse_create


class RealSeparator:
    """mlx_audio_separator.Separator with weights in `models_dir`, progress taken from the inference loops
    and .ckpt read by read_ckpt.

    No rescaling: the library brings the mix and every stem that exceeds it to 1.0, and writes 16-bit
    PCM if the input is. Here mix and stems stay as they are and are written in Float32 without clipping,
    so in Pro "Other = mix − sum" is exact and the voice does not leak into Other."""

    def __init__(self, models_dir, output_dir, on_step):
        import logging

        block_network()
        from mlx_audio_separator import Separator
        from mlx_audio_separator.separator.architectures import mdxc_separator
        from mlx_audio_separator.separator.models.roformer import loader

        loader._load_state_dict = read_ckpt

        def counted(iterable, *args, **kwargs):
            items = list(iterable)
            for index, item in enumerate(items):
                yield item
                on_step(index + 1, len(items))

        mdxc_separator.tqdm = counted

        import mlx_audio_io as mac
        from mlx_audio_separator.separator import common_separator
        from mlx_audio_separator.utils import performance

        def save_unclipped(task):
            mac.save(task.stem_path, task.stem_source, task.sample_rate, layout=task.layout,
                     encoding="float32", clip=False)

        common_separator.save_stem = performance.save_stem = save_unclipped

        def no_download(_self, url, output_path):
            if not os.path.isfile(output_path):
                raise missing_weights(os.path.basename(output_path))

        Separator.download_file_if_not_exists = no_download
        self.inner = Separator(log_level=logging.WARNING, model_file_dir=str(models_dir),
                               output_dir=str(output_dir), normalization_threshold=1.0, sample_rate=SAMPLE_RATE)

    def load_model(self, name):
        self.inner.load_model(name)

    def separate(self, path, custom_output_names=None):
        # The constructor accepts at most 1.0; on the model instance the threshold is removed.
        self.inner.model_instance.normalization_threshold = float("inf")
        files = self.inner.separate(path, custom_output_names)
        failed = getattr(self.inner, "failed_files", [])
        if failed:
            raise RuntimeError(failed[0][1])
        return files


make_separator = RealSeparator


# --- lavoro ---------------------------------------------------------------------------------------

def _load(path, sr=None):
    """(frame, 2) float32 and the rate. The mix is loaded the way the library loads it (same resampler)."""
    import mlx_audio_io as mac
    import numpy as np
    data, rate = mac.load(str(path), sr=sr, dtype="float32", layout="channels_last")
    data = np.array(data, dtype=np.float32)
    if data.ndim == 1:
        data = data[:, None]
    if data.shape[1] == 1:
        data = np.repeat(data, 2, axis=1)
    return data[:, :2], int(rate)


def _save(path, data):
    import mlx_audio_io as mac
    import numpy as np
    mac.save(str(path), np.ascontiguousarray(data, dtype=np.float32), SAMPLE_RATE, layout="channels_last",
             encoding="float32", clip=False)


def _run_model(models, model, input_path, folder, stems, on_step):
    """One model over the whole file: {stem: path}. Every requested stem must come out."""
    separator = make_separator(models, folder, on_step)
    separator.load_model(model)
    files = separator.separate(str(input_path), {stem: stem for stem in stems})
    by_name = {os.path.splitext(os.path.basename(f))[0].lower(): f for f in files}
    found = {}
    for stem in stems:
        path = by_name.get(stem)
        if path is None:
            path = next((f for f in files if f"({stem})" in os.path.basename(f).lower()), None)
        if path is None:
            raise Failure("model", "separationFailed")
        found[stem] = os.path.join(folder, path) if not os.path.isabs(path) else path
    return found


def _model_stem(path, frames):
    """One stem of the model, at 44.1 kHz and at most `frames` frames (the zeros added at the end removed)."""
    data, rate = _load(path)
    if rate != SAMPLE_RATE:
        raise Failure("model", "separationFailed")
    return data[:frames]


def check_model_yaml(path):
    """The library reads the model's YAML with yaml.FullLoader, which builds no objects but still accepts
    Python names (!!python/name:os.system). The YAMLs of the catalog use only !!python/tuple: the file is
    read first with SafeLoader plus tuples, and anything else is refused before the library sees it."""
    import yaml

    class Loader(yaml.SafeLoader):
        pass

    Loader.add_constructor("tag:yaml.org,2002:python/tuple", lambda loader, node: tuple(loader.construct_sequence(node)))
    try:
        with open(path, "rb") as f:
            yaml.load(f, Loader=Loader)
    except (yaml.YAMLError, OSError):
        raise Failure("model", "separationFailed")


def separate(level, input_path, output, models, protocol):
    import numpy as np

    needed = [SW] if level == "intermediate" else [VOCALS, SW]
    yamls = [os.path.splitext(n)[0] + ".yaml" for n in needed]
    for name in needed + yamls + ["download_checks.json"]:
        if not os.path.isfile(os.path.join(models, name)):
            raise missing_weights(name)
    for name in yamls:
        check_model_yaml(os.path.join(models, name))
    if not os.path.isfile(input_path):
        raise Failure("unsupported", "unsupported")
    try:
        # The same loading (and resampler) as the library: it is the mix the model sees.
        mix, _ = _load(input_path, sr=SAMPLE_RATE)
    except Exception:
        raise Failure("unsupported", "unsupported")
    frames = len(mix)
    if frames == 0:
        raise Failure("unsupported", "unsupported")

    tmp = os.path.join(output, ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    _current_tmp[0] = tmp
    final = os.path.join(tmp, "stems")
    os.makedirs(final)

    if not np.any(mix):
        # The library rejects an all-zero mix: 6 silent stems, as Base does.
        protocol.progress(0.96, "writingStems")
        silence = np.zeros((frames, 2), dtype=np.float32)
        for stem in SW_STEMS:
            _save(os.path.join(final, FILE_NAMES[stem]), silence)
        return _place(output, final, tmp)

    source = input_path
    if frames < MIN_FRAMES:
        # Below ~1024 frames the library's STFT fails: the model receives 1 s with zeros at the end.
        padded = np.zeros((MIN_FRAMES, 2), dtype=np.float32)
        padded[:frames] = mix
        source = os.path.join(tmp, "input-padded.wav")
        _save(source, padded)

    if level == "intermediate":
        protocol.progress(0.02, "preparingModel")
        sw = _run_model(models, SW, source, os.path.join(tmp, "sw"), SW_STEMS,
                        protocol.stage(0.05, 0.95, "separating"))
        protocol.progress(0.96, "writingStems")
        for stem, path in sw.items():
            target = os.path.join(final, FILE_NAMES[stem])
            if source == input_path:
                os.replace(path, target)
            else:
                _save(target, _model_stem(path, frames))
    else:
        protocol.progress(0.02, "loadingVocalsModel")
        voice = _run_model(models, VOCALS, source, os.path.join(tmp, "voce"), ("vocals",),
                           protocol.stage(0.04, 0.45, "separatingVocals"))
        protocol.progress(0.46, "loadingInstrumentsModel")
        sw = _run_model(models, SW, source, os.path.join(tmp, "sw"), ("drums", "bass", "guitar", "piano"),
                        protocol.stage(0.48, 0.90, "separatingInstruments"))
        protocol.progress(0.92, "rebuildingOther")
        parts = {"vocals": voice["vocals"], **sw}
        loaded = {stem: _model_stem(path, frames) for stem, path in parts.items()}
        n = min(frames, *(len(d) for d in loaded.values()))
        loaded = {stem: data[:n] for stem, data in loaded.items()}
        loaded["other"] = mix[:n] - sum(loaded.values())
        protocol.progress(0.96, "writingStems")
        for stem, data in loaded.items():
            _save(os.path.join(final, FILE_NAMES[stem]), data)

    return _place(output, final, tmp)


def _place(output, final, tmp):
    """The 6 stems from `final` to the real names in `output`, then the temporary folder is removed."""
    files = {}
    for stem in SW_STEMS:
        target = os.path.join(output, FILE_NAMES[stem])
        os.replace(os.path.join(final, FILE_NAMES[stem]), target)
        files[stem] = target
    shutil.rmtree(tmp, ignore_errors=True)
    _current_tmp[0] = None
    return files


# --- CLI ------------------------------------------------------------------------------------------

_current_tmp = [None]


def parse(argv):
    parser = argparse.ArgumentParser(prog="stelix_sidecar.py")
    parser.add_argument("--level", choices=("intermediate", "pro"), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--models", required=True)
    return parser.parse_args(argv)


def main(argv=None, out=None):
    args = parse(argv)
    protocol = Protocol(out or sys.stdout)
    try:
        os.makedirs(args.output, exist_ok=True)
        files = separate(args.level, args.input, args.output, args.models, protocol)
    except Failure as failure:
        _cleanup()
        protocol.send({"error": failure.code, "message": failure.message, "detail": failure.detail})
        return 1
    except OSError:
        _cleanup()
        protocol.send({"error": "file", "message": "stemsUnwritable", "detail": None})
        return 1
    except Exception:
        _cleanup()
        protocol.send({"error": "model", "message": "separationFailed", "detail": None})
        return 1
    protocol.send({"done": True, "files": files})
    return 0


def _cleanup():
    tmp = _current_tmp[0]
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
        _current_tmp[0] = None


def _watch_stdin():
    """When stdin closes (the engine died or closed the pipe) the process exits at once."""
    try:
        while os.read(0, 4096):  # a piece at a time and discarded: nothing grows in memory if data arrives
            pass
    finally:
        _cleanup()
        os._exit(1)


def entry(argv=None):
    """Real start: stdout stays only for the protocol, everything else (log, print, tqdm) goes to stderr."""
    import signal

    # StelixEngine ignores SIGTERM and an ignored signal passes to children: here SIGTERM goes back to closing
    # the process at once (half-written files are removed by the engine with the working folder).
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    protocol_out = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    threading.Thread(target=_watch_stdin, name="stdin-watch", daemon=True).start()
    code = main(argv, out=protocol_out)
    protocol_out.flush()
    os._exit(code)


if __name__ == "__main__":
    entry()
