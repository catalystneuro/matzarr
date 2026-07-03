"""Open a matzarr index with zarr-python, via fsspec reference (kerchunk) refs.

The manifest translates 1:1 into kerchunk references: metadata documents are
inlined, byte-range entries become [path, offset, length] triples. With that,
zarr-python (or xarray) can read a .mat file's arrays directly:

    from shim_kerchunk import open_index
    g = open_index("data.mat.zarr")
    g["big"][:10, :10]        # same values as MATLAB's big(1:10, 1:10)
"""
import base64
import json
import pathlib


def refs_from_index(index_dir):
    index = pathlib.Path(index_dir)
    refs = {}
    for p in index.rglob("zarr.json"):
        refs[p.relative_to(index).as_posix()] = p.read_text()
    manifest = json.loads((index / "manifest.json").read_text())
    default = manifest.get("default_path")
    for key, ent in manifest["chunks"].items():
        if "inline" in ent:
            refs[key] = "base64:" + ent["inline"]
        else:
            path = ent.get("path", default)
            target = (index / path).resolve().as_posix()
            refs[key] = [target, ent["offset"], ent["length"]]
    return {"version": 1, "refs": refs}


def open_index(index_dir):
    import fsspec
    import zarr

    fs = fsspec.filesystem("reference", fo=refs_from_index(index_dir), asynchronous=True)
    store = zarr.storage.FsspecStore(fs, read_only=True)
    return zarr.open_group(store, mode="r")


if __name__ == "__main__":
    import sys

    import numpy as np

    g = open_index(sys.argv[1])
    # Fixture written by tools/make_shim_fixture.m: big = (1:n)'*0.25 pattern
    big = g["big"]
    r, c = big.shape
    expected = (np.arange(1, r * c + 1, dtype="float64") * 0.25).reshape(
        (c, r)).T  # MATLAB column-major fill
    np.testing.assert_array_equal(big[...], expected)
    assert big.attrs["MATLAB_class"] == "double"
    labels = g["labels"]
    assert labels.attrs["zarr_dtype"] == "object"
    assert json.loads(str(labels[0, 0]))["path"].startswith("/#refs#/")
    print(f"shim: zarr-python read the .mat index OK (big {r}x{c}, refs translated)")
