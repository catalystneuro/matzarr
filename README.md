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

**Pre-alpha.** The de-risking spike (`spike/`) is complete and green — see
[PLAN.md](PLAN.md) for the design, spike findings (userblock offsets,
zero-permute reads, reference resolution), and milestones. Foundation work
(manifest store, zlib/shuffle codecs) lands in zarr-matlab first.

## License

MIT. A [CatalystNeuro](https://catalystneuro.com) project.
