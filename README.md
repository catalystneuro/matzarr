# matzarr

Read `.mat` files from cloud storage, efficiently, by indexing them as
virtual [Zarr](https://zarr.dev) stores.

A `.mat` v7.3 file is an HDF5 file. `matzarr` scans it once and produces a
small sidecar index — ordinary Zarr v3 metadata (with consolidated metadata)
plus a chunk manifest mapping each chunk to a byte range in the original
file. Reading then costs **one request for the entire file structure** and
one ranged request per touched chunk, via
[zarr-matlab](https://github.com/catalystneuro/zarr-matlab):

```matlab
matzarr.index("data.mat")                          % once, wherever the file lives
m = matzarr.open("https://bucket/data.mat.zarr");  % anywhere
x = m.bigMatrix(1e6:2e6, 1:10);                    % fetches only those chunks
```

MATLAB semantics (cell arrays, structs, char, logical) are reconstructed
from the `MATLAB_class` conventions; HDF5 object references are translated
at indexing time into portable JSON references using
[hdmf-zarr's conventions](https://hdmf-zarr.readthedocs.io/en/latest/storage.html).

## Status

**Alpha — the core works end to end.** Indexing and reading are implemented
and tested: a 14-type round-trip matrix (numerics, char, logical, nested
cells, structs, struct arrays, empties) with MATLAB's own `save`/`load` as
the oracle; lazy slicing that reads exactly the intersecting chunks (request
counts are asserted in CI); reading over HTTP; compressed (deflate) and
uncompressed (`-nocompression`) files; HDF5 1.10 and 1.14 address semantics
(self-verified per file at index time).

The index is also readable from **Python**: `tools/shim_kerchunk.py`
translates the manifest to kerchunk references, so zarr-python/xarray can
read your `.mat` files too — verified in CI.

Not yet supported (clear errors, never silent corruption): complex numbers
(HDF5 compound), sparse matrices, `string` arrays, tables, objects, and
function handles. See [PLAN.md](PLAN.md) for design and milestones.

## License

MIT. A [CatalystNeuro](https://catalystneuro.com) project.
