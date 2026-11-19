# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.

"""Sidecar tests with a fake Separator that writes known sines (no real model)."""

import collections
import io
import json
import os
import pickle
import subprocess
import sys
import time
import types
import zipfile
from pathlib import Path

import mlx_audio_io as mac
import numpy as np
import pytest

import stelix_sidecar

SR = 44_100
FRAMES = SR  # 1 s
SIDECAR_DIR = Path(__file__).resolve().parent.parent
JOB_STEPS = {"readingFile", "preparingModel", "separating", "loadingVocalsModel", "separatingVocals",
             "loadingInstrumentsModel", "separatingInstruments", "rebuildingOther", "writingStems"}
CANONICAL = {"vocals.wav", "drums.wav", "bass.wav", "guitar.wav", "piano.wav", "other.wav"}

# Frequencies of the fake sines: which model wrote which stem is recognized by the tone.
SW_TONES = {"vocals": 880.0, "drums": 110.0, "bass": 55.0, "other": 1760.0, "guitar": 330.0, "piano": 660.0}
VOCAL_TONES = {"vocals": 440.0, "instrumental": 220.0}


def sine(freq, frames=FRAMES, amp=0.1):
    t = np.arange(frames, dtype=np.float64) / SR
    mono = (amp * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    return np.stack([mono, mono * 0.5], axis=1)


def write_wav(path, data, sr=SR):
    mac.save(str(path), np.ascontiguousarray(data, dtype=np.float32), sr, layout="channels_last",
             encoding="float32", clip=False)


def read_wav(path):
    data, sr = mac.load(str(path), sr=None, dtype="float32", layout="channels_last")
    assert sr == SR
    return np.array(data)


class FakeSeparator:
    """Like mlx_audio_separator.Separator: load_model(name), separate(file, custom_output_names)."""

    loaded = []
    sleep = 0.0

    def __init__(self, models_dir, output_dir, on_step):
        self.output_dir = Path(output_dir)
        self.on_step = on_step
        self.model = None

    def load_model(self, name):
        self.model = name
        FakeSeparator.loaded.append(name)

    def separate(self, path, custom_output_names=None):
        tones = VOCAL_TONES if "ep_317" in self.model else SW_TONES
        frames = len(read_wav(path))
        files = []
        self.output_dir.mkdir(parents=True, exist_ok=True)
        for step, (stem, freq) in enumerate(tones.items()):
            if FakeSeparator.sleep:
                time.sleep(FakeSeparator.sleep)
            self.on_step(step + 1, len(tones))
            name = (custom_output_names or {}).get(stem, f"x_({stem})_{self.model}")
            out = self.output_dir / f"{name}.wav"
            write_wav(out, sine(freq, frames))
            files.append(str(out))
        return files


@pytest.fixture
def job(tmp_path, monkeypatch):
    FakeSeparator.loaded = []
    FakeSeparator.sleep = 0.0
    monkeypatch.setattr(stelix_sidecar, "make_separator", FakeSeparator)
    models = tmp_path / "roformer"
    models.mkdir()
    for name in ("BS-Roformer-SW.ckpt", "BS-Roformer-SW.yaml", "model_bs_roformer_ep_317_sdr_12.9755.ckpt",
                 "model_bs_roformer_ep_317_sdr_12.9755.yaml", "download_checks.json"):
        (models / name).write_text("x")
    mix = sine(1000.0, amp=0.3) + sine(123.0, amp=0.2) + np.random.default_rng(1).normal(0, 0.01, (FRAMES, 2))
    source = tmp_path / "mix.wav"
    write_wav(source, mix)
    output = tmp_path / "out"
    output.mkdir()

    def run(level):
        out = io.StringIO()
        code = stelix_sidecar.main(["--level", level, "--input", str(source), "--output", str(output),
                                  "--models", str(models)], out=out)
        lines = [json.loads(line) for line in out.getvalue().splitlines()]
        return code, lines

    return types.SimpleNamespace(run=run, source=source, output=output, models=models)


def test_pro_other_is_residual(job):
    code, lines = job.run("pro")
    assert code == 0, lines
    assert FakeSeparator.loaded == ["model_bs_roformer_ep_317_sdr_12.9755.ckpt", "BS-Roformer-SW.ckpt"]

    mix = read_wav(job.source)
    stems = {name: read_wav(job.output / f"{name}.wav") for name in ("vocals", "drums", "bass", "guitar", "piano")}
    other = read_wav(job.output / "other.wav")
    assert other.shape == mix.shape
    np.testing.assert_allclose(other, mix - sum(stems.values()), atol=1e-5)
    # The voice comes from the specialist (440 Hz), not from SW (880 Hz).
    np.testing.assert_allclose(stems["vocals"], sine(VOCAL_TONES["vocals"]), atol=1e-6)
    np.testing.assert_allclose(stems["drums"], sine(SW_TONES["drums"]), atol=1e-6)


def test_intermediate_writes_six_canonical_files(job):
    code, lines = job.run("intermediate")
    assert code == 0, lines
    assert FakeSeparator.loaded == ["BS-Roformer-SW.ckpt"]
    assert set(os.listdir(job.output)) == CANONICAL  # no .tmp or temporary files
    done = lines[-1]
    assert done["done"] is True
    assert set(done["files"]) == {"vocals", "drums", "bass", "other", "piano", "guitar"}
    assert done["files"]["vocals"] == str(job.output / "vocals.wav")
    assert done["files"]["guitar"] == str(job.output / "guitar.wav")
    np.testing.assert_allclose(read_wav(job.output / "other.wav"), sine(SW_TONES["other"]), atol=1e-6)


def test_progress_lines_are_json(job):
    code, lines = job.run("pro")
    assert code == 0
    progress = [line for line in lines if "progress" in line]
    assert len(progress) >= 4
    values = [line["progress"] for line in progress]
    assert values == sorted(values)
    assert all(0.0 <= v <= 1.0 for v in values)
    steps = [line["step"] for line in progress]
    assert set(steps) <= JOB_STEPS
    # Pro says what it is doing, in order.
    assert [s for i, s in enumerate(steps) if i == 0 or steps[i - 1] != s] == [
        "loadingVocalsModel", "separatingVocals", "loadingInstrumentsModel", "separatingInstruments",
        "rebuildingOther", "writingStems"]
    assert lines[-1]["done"] is True
    assert all(set(line) in ({"progress", "step"}, {"done", "files"}) for line in lines)


def test_missing_weights_is_an_error_line(job):
    (job.models / "BS-Roformer-SW.ckpt").unlink()
    code, lines = job.run("intermediate")
    assert code == 1
    assert lines[-1] == {"error": "weights", "message": "missingWeights", "detail": "BS-Roformer-SW.ckpt"}
    assert FakeSeparator.loaded == []
    assert os.listdir(job.output) == []


def test_missing_input_is_unsupported(job):
    job.source.unlink()
    code, lines = job.run("intermediate")
    assert code == 1
    assert lines[-1] == {"error": "unsupported", "message": "unsupported", "detail": None}


def test_separator_failure_cleans_tmp(job, monkeypatch):
    def broken(self, path, custom_output_names=None):
        raise RuntimeError("Metal OOM")

    monkeypatch.setattr(FakeSeparator, "separate", broken)
    code, lines = job.run("pro")
    assert code == 1
    assert lines[-1] == {"error": "model", "message": "separationFailed", "detail": None}
    assert os.listdir(job.output) == []


@pytest.fixture
def unblocked(monkeypatch):
    """block_network() changes requests and socket for the whole process: here they are put back."""
    import socket

    import requests

    for owner, name in ((requests.Session, "request"), (socket.socket, "connect"),
                        (socket.socket, "connect_ex"), (socket, "create_connection")):
        monkeypatch.setattr(owner, name, getattr(owner, name))


def test_network_is_blocked(unblocked):
    import requests

    stelix_sidecar.block_network()
    with pytest.raises(stelix_sidecar.NetworkBlocked):
        requests.get("https://example.com", timeout=1)


def test_socket_connect_is_blocked(unblocked):
    import socket

    stelix_sidecar.block_network()
    with pytest.raises(stelix_sidecar.NetworkBlocked):
        socket.create_connection(("127.0.0.1", 9), timeout=1)
    with socket.socket() as sock, pytest.raises(stelix_sidecar.NetworkBlocked):
        sock.connect(("127.0.0.1", 9))
    with socket.socket() as sock, pytest.raises(stelix_sidecar.NetworkBlocked):
        sock.connect_ex(("127.0.0.1", 9))


INSTALLED_ROFORMER = Path.home() / "Library/Application Support/Stelix/Models/roformer"


@pytest.mark.skipif(not (INSTALLED_ROFORMER / stelix_sidecar.SW).is_file(), reason="the installed SW weights are required")
def test_real_load_model_makes_no_requests(tmp_path, unblocked, monkeypatch):
    """The real loading of SW, with the weights and a minimal download_checks.json: zero network requests."""
    import socket

    import requests

    models = tmp_path / "models"
    models.mkdir()
    for name in (stelix_sidecar.SW, "BS-Roformer-SW.yaml"):
        (models / name).symlink_to(INSTALLED_ROFORMER / name)
    empty = {key: {} for key in ("vr_download_list", "mdx_download_list", "demucs_download_list",
                                 "mdx23c_download_list", "roformer_download_list")}
    (models / "download_checks.json").write_text(json.dumps(empty))

    calls = []
    original_connect = socket.socket.connect
    original_request = requests.Session.request

    def counted_connect(self, *args, **kwargs):
        calls.append(("connect", args))
        return original_connect(self, *args, **kwargs)

    def counted_request(self, *args, **kwargs):
        calls.append(("request", args))
        return original_request(self, *args, **kwargs)

    monkeypatch.setattr(socket.socket, "connect", counted_connect)
    monkeypatch.setattr(requests.Session, "request", counted_request)
    out = tmp_path / "out"
    out.mkdir()
    separator = stelix_sidecar.RealSeparator(str(models), str(out), lambda step, total: None)
    separator.load_model(stelix_sidecar.SW)
    assert separator.inner.model_instance is not None
    assert calls == []


@pytest.fixture
def make_ckpt(tmp_path, monkeypatch):
    """Writes a hand-made torch .ckpt (zip + pickle with persistent storages).

    Each entry is (name, storage, offset, shape, stride); the storage is a float32 array."""
    torch = types.ModuleType("torch")
    utils = types.ModuleType("torch._utils")

    class FloatStorage:
        pass

    def _rebuild_tensor_v2(*args):
        raise AssertionError("not called by writing")

    FloatStorage.__module__, FloatStorage.__qualname__ = "torch", "FloatStorage"
    _rebuild_tensor_v2.__module__, _rebuild_tensor_v2.__qualname__ = "torch._utils", "_rebuild_tensor_v2"
    torch.FloatStorage, utils._rebuild_tensor_v2 = FloatStorage, _rebuild_tensor_v2
    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "torch._utils", utils)

    class Ref:
        def __init__(self, key, numel):
            self.key, self.numel = key, numel

    class Tensor:
        def __init__(self, ref, offset, shape, stride):
            self.args = (ref, offset, shape, stride, False, collections.OrderedDict())

        def __reduce__(self):
            return _rebuild_tensor_v2, self.args

    class Pickler(pickle.Pickler):
        def persistent_id(self, obj):
            if isinstance(obj, Ref):
                return ("storage", FloatStorage, obj.key, "cpu", obj.numel)
            return None

    def write(entries, name="fake", compression=zipfile.ZIP_STORED):
        """Entries that pass the very same array share one storage, as views do in torch."""
        state = collections.OrderedDict()
        blobs = {}
        keys = {}
        for key, storage, offset, shape, stride in entries:
            ref = keys.setdefault(id(storage), str(len(keys)))
            storage = np.asarray(storage, dtype=np.float32)
            state[key] = Tensor(Ref(ref, storage.size), offset, shape, stride)
            blobs[ref] = storage.tobytes()
        buffer = io.BytesIO()
        Pickler(buffer, protocol=2).dump(state)
        path = tmp_path / f"{name}.ckpt"
        with zipfile.ZipFile(path, "w", compression=compression) as z:
            z.writestr(f"{name}/data.pkl", buffer.getvalue())
            for key, blob in blobs.items():
                z.writestr(f"{name}/data/{key}", blob)
        return str(path)

    return write


def test_ckpt_reader_reads_tensors(make_ckpt):
    """Also with transposed strides and with an offset in the storage."""
    base = np.arange(12, dtype=np.float32).reshape(3, 4)
    bias = np.array([0.5, -1.5], dtype=np.float32)
    path = make_ckpt([
        ("weight", base.ravel(), 0, (4, 3), (1, 4)),  # base.T
        ("bias", np.concatenate([[9.0], bias]), 1, (2,), (1,)),  # storage [9, 0.5, -1.5], dall'offset 1
    ])
    loaded = stelix_sidecar.read_ckpt(path)
    np.testing.assert_array_equal(loaded["weight"], base.T)
    np.testing.assert_array_equal(loaded["bias"], bias)


@pytest.mark.parametrize("offset, shape, stride", [
    (0, (4, 4), (4, 1)),   # 16 elements from a storage of 12
    (11, (2,), (1,)),      # the offset goes past the end
    (12, (), ()),          # scalar outside the storage
    (0, (3,), (-1,)),      # negative stride: it would read before the start
    (0, (-1,), (1,)),      # size negativa
    (-1, (2,), (1,)),      # offset negativo
])
def test_ckpt_reader_refuses_out_of_bounds(make_ckpt, offset, shape, stride):
    path = make_ckpt([("weight", np.arange(12), offset, shape, stride)])
    with pytest.raises(pickle.UnpicklingError):
        stelix_sidecar.read_ckpt(path)


def test_ckpt_reader_accepts_empty_and_scalar(make_ckpt):
    path = make_ckpt([("empty", np.arange(12), 0, (0, 3), (3, 1)), ("scalar", np.arange(12), 11, (), ())])
    loaded = stelix_sidecar.read_ckpt(path)
    assert loaded["empty"].shape == (0, 3)
    assert float(loaded["scalar"]) == 11.0


def test_ckpt_reader_refuses_a_tensor_larger_than_the_file(make_ckpt):
    """Stride 0 repeats one element: in bounds, but a file of a few hundred bytes would ask for 4 MB
    (or 4 TB) of memory."""
    path = make_ckpt([("weight", np.arange(12), 0, (1_000_000,), (0,))])
    assert os.path.getsize(path) < 4_000
    with pytest.raises(pickle.UnpicklingError):
        stelix_sidecar.read_ckpt(path)


def test_ckpt_reader_refuses_views_that_add_up_to_more_than_the_file(make_ckpt):
    """Each view fits its storage, but 200 of them over the same 16 KB are 3.2 MB."""
    storage = np.arange(4096)
    path = make_ckpt([(f"view{index}", storage, 0, (4096,), (1,)) for index in range(200)])
    assert os.path.getsize(path) < 100_000
    with pytest.raises(pickle.UnpicklingError):
        stelix_sidecar.read_ckpt(path)


def test_ckpt_reader_refuses_a_compressed_storage_larger_than_the_file(make_ckpt):
    """16 MB of zeros deflate to a few KB: the storage is refused before it is inflated."""
    path = make_ckpt([("weight", np.zeros(4_000_000), 0, (2,), (1,))], compression=zipfile.ZIP_DEFLATED)
    assert os.path.getsize(path) < 100_000
    with pytest.raises(pickle.UnpicklingError):
        stelix_sidecar.read_ckpt(path)


def test_ckpt_reader_reads_views_that_share_a_storage(make_ckpt):
    """Two tensors over one storage are read, and the storage counts once."""
    storage = np.arange(12)
    path = make_ckpt([("head", storage, 0, (4,), (1,)), ("tail", storage, 8, (4,), (1,))])
    loaded = stelix_sidecar.read_ckpt(path)
    np.testing.assert_array_equal(loaded["head"], [0, 1, 2, 3])
    np.testing.assert_array_equal(loaded["tail"], [8, 9, 10, 11])


@pytest.mark.parametrize("name", [stelix_sidecar.SW, stelix_sidecar.VOCALS])
def test_ckpt_reader_reads_the_installed_checkpoints(name):
    """The memory budgets are the size of the file: the real checkpoints must stay inside them."""
    path = INSTALLED_ROFORMER / name
    if not path.is_file():
        pytest.skip("the installed weights are required")
    state = stelix_sidecar.read_ckpt(str(path))
    assert len(state) > 100
    assert sum(value.nbytes for value in state.values()) <= path.stat().st_size


def test_ckpt_reader_refuses_other_globals(tmp_path):
    path = tmp_path / "evil.ckpt"
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("evil/data.pkl", pickle.dumps(os.system, protocol=2))
    with pytest.raises(pickle.UnpicklingError):
        stelix_sidecar.read_ckpt(str(path))


def test_stdin_close_exits(job, tmp_path):
    """The real sidecar, launched separately with a slow Separator: with stdin closed, it exits within 1 s."""
    script = (
        "import sys; sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2]);"
        "import stelix_sidecar, test_sidecar;"
        "test_sidecar.FakeSeparator.sleep = 30;"
        "stelix_sidecar.make_separator = test_sidecar.FakeSeparator;"
        "stelix_sidecar.entry(sys.argv[3:])"
    )
    proc = subprocess.Popen(
        [sys.executable, "-I", "-c", script, str(SIDECAR_DIR), str(Path(__file__).parent),
         "--level", "intermediate", "--input", str(job.source), "--output", str(job.output),
         "--models", str(job.models)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    first = json.loads(proc.stdout.readline())  # it has started and writes the protocol on stdout
    assert "progress" in first
    # stdin is closed when the fake separator has created its folder and is stopped in the sleep:
    # before that, its mkdir(parents=True) could recreate .tmp between the cleanup and os._exit (a race
    # harmless in production, because the engine deletes the working folder, but not in tests).
    deadline = time.monotonic() + 5
    while not (job.output / ".tmp" / "sw").exists():
        assert time.monotonic() < deadline, "the fake separator did not start"
        time.sleep(0.01)
    proc.stdin.close()
    start = time.monotonic()
    code = proc.wait(timeout=5)
    assert time.monotonic() - start < 1.0
    assert code != 0
    assert not (job.output / ".tmp").exists()


def test_real_separator_writes_unclipped_float32(tmp_path):
    """Stems above 1.0 stay whole: a clip or a rescaling would dirty Other in Pro."""
    import mlx.core as mx
    from mlx_audio_separator.separator import common_separator
    from mlx_audio_separator.utils.performance import SaveTask

    stelix_sidecar.RealSeparator(tmp_path / "models", tmp_path / "out", lambda step, total: None)
    data = (sine(440.0, amp=1.5)).astype(np.float32)
    path = tmp_path / "loud.wav"
    common_separator.save_stem(SaveTask(stem_path=str(path), stem_source=mx.array(data), sample_rate=SR,
                                        layout="channels_last", encoding="pcm16", bitrate="auto"))
    assert mac.info(str(path)).subtype == "float32"
    np.testing.assert_allclose(read_wav(path), data, atol=1e-6)


def test_real_separator_turns_off_peak_scaling(tmp_path):
    separator = stelix_sidecar.RealSeparator(tmp_path / "models", tmp_path / "out", lambda step, total: None)
    seen = {}

    class Model:
        normalization_threshold = 1.0

    def fake_separate(path, names):
        seen["threshold"] = separator.inner.model_instance.normalization_threshold
        return []

    separator.inner.model_instance = Model()
    separator.inner.separate = fake_separate
    separator.inner.failed_files = []
    separator.separate("x.wav", {})
    assert seen["threshold"] == float("inf")


def test_bundled_site_packages_on_path(tmp_path):
    """In the bundle `python3 -I stelix_sidecar.py` is launched: -I ignores PYTHONPATH, so the script
    adds by itself the site-packages next to it (and only that)."""
    (tmp_path / "site-packages").mkdir()
    (tmp_path / "site-packages" / "solo_nel_bundle.py").write_text("VALUE = 42\n")
    script = tmp_path / "stelix_sidecar.py"
    script.write_text((SIDECAR_DIR / "stelix_sidecar.py").read_text())
    probe = (
        "import runpy, sys; runpy.run_path(sys.argv[1], run_name='probe');"
        "import solo_nel_bundle; print(solo_nel_bundle.VALUE)"
    )
    result = subprocess.run([sys.executable, "-I", "-c", probe, str(script)], capture_output=True, text=True,
                            env={"PYTHONPATH": "/nonexistent"}, timeout=30)
    assert result.stdout.strip() == "42", result.stderr


def test_sigterm_works_even_if_inherited_as_ignored(job):
    """StelixEngine ignores SIGTERM and the child inherits it: the sidecar restores the default action."""
    import signal

    script = (
        "import sys; sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2]);"
        "import stelix_sidecar, test_sidecar;"
        "test_sidecar.FakeSeparator.sleep = 30;"
        "stelix_sidecar.make_separator = test_sidecar.FakeSeparator;"
        "stelix_sidecar.entry(sys.argv[3:])"
    )
    proc = subprocess.Popen(
        [sys.executable, "-I", "-c", script, str(SIDECAR_DIR), str(Path(__file__).parent),
         "--level", "intermediate", "--input", str(job.source), "--output", str(job.output),
         "--models", str(job.models)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        preexec_fn=lambda: signal.signal(signal.SIGTERM, signal.SIG_IGN),
    )
    assert "progress" in json.loads(proc.stdout.readline())
    start = time.monotonic()
    proc.send_signal(signal.SIGTERM)
    code = proc.wait(timeout=5)
    assert time.monotonic() - start < 0.5
    assert code == -signal.SIGTERM
    proc.stdin.close()


@pytest.mark.parametrize("level", ["intermediate", "pro"])
def test_silent_input_gives_six_silent_stems(job, level):
    """The library rejects an all-zero mix ("empty or not valid"): the sidecar writes 6 silent stems
    of the same length, like Base, without loading the models."""
    write_wav(job.source, np.zeros((FRAMES, 2), dtype=np.float32))
    code, lines = job.run(level)
    assert code == 0, lines
    assert FakeSeparator.loaded == []
    assert set(os.listdir(job.output)) == CANONICAL
    for name in CANONICAL:
        data = read_wav(job.output / name)
        assert data.shape == (FRAMES, 2)
        assert not np.any(data)


@pytest.mark.parametrize("level", ["intermediate", "pro"])
def test_very_short_input_is_padded_then_trimmed(job, level, monkeypatch):
    """Below ~1024 frames the library's STFT fails: the model receives the file stretched with
    zeros up to 1 s, and the stems return to the real length."""
    seen = []
    original = FakeSeparator.separate

    def spy(self, path, custom_output_names=None):
        seen.append(len(read_wav(path)))
        return original(self, path, custom_output_names)

    monkeypatch.setattr(FakeSeparator, "separate", spy)
    short = sine(1000.0, frames=441, amp=0.3)
    write_wav(job.source, short)
    code, lines = job.run(level)
    assert code == 0, lines
    assert seen and all(n >= stelix_sidecar.MIN_FRAMES for n in seen)
    for name in CANONICAL:
        assert read_wav(job.output / name).shape == (441, 2)
    if level == "pro":
        parts = sum(read_wav(job.output / n) for n in ("vocals.wav", "drums.wav", "bass.wav", "guitar.wav", "piano.wav"))
        np.testing.assert_allclose(read_wav(job.output / "other.wav"), short - parts, atol=1e-5)


PYTHON_TAG_YAMLS = [
    "extra: !!python/name:os.system\n",
    "a: !!python/object/apply:os.system ['true']\n",
    "a: !!python/object/new:os.system ['true']\n",
    "m: !!python/module:os\n",
]


@pytest.mark.parametrize("level", ["intermediate", "pro"])
@pytest.mark.parametrize("text", PYTHON_TAG_YAMLS)
def test_yaml_with_python_tags_is_refused_before_the_library(job, level, text):
    """The library reads the YAML with yaml.FullLoader, which accepts !!python/name: anything beyond the
    tuples of the real configs is refused before the library sees it."""
    yaml_name = "BS-Roformer-SW.yaml" if level == "intermediate" else "model_bs_roformer_ep_317_sdr_12.9755.yaml"
    (job.models / yaml_name).write_text(text)
    code, lines = job.run(level)
    assert code == 1
    assert lines[-1] == {"error": "model", "message": "separationFailed", "detail": None}
    assert FakeSeparator.loaded == []


def test_yaml_with_tuples_passes_the_check(tmp_path):
    path = tmp_path / "ok.yaml"
    path.write_text("model:\n  freqs_per_bands: !!python/tuple\n  - 2\n  - 4\n  dim: 384\n")
    stelix_sidecar.check_model_yaml(str(path))


@pytest.mark.parametrize("name", ["BS-Roformer-SW.yaml", "model_bs_roformer_ep_317_sdr_12.9755.yaml"])
def test_installed_yamls_pass_the_check(name):
    path = INSTALLED_ROFORMER / name
    if not path.is_file():
        pytest.skip("the installed weights are required")
    stelix_sidecar.check_model_yaml(str(path))
