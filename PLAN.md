# Plan: cloud-readable .mat files and NWB-Zarr in MATLAB

Two goals, one architecture:

- **G1 (NWB):** read (then write) NWB files stored as Zarr v3 per hdmf-zarr's
  conventions ([hdmf-dev/hdmf-zarr#325](https://github.com/hdmf-dev/hdmf-zarr/pull/325)),
  with an eventual MatNWB backend.
- **G2 (.mat in the cloud):** read `.mat` (v7.3 = HDF5) files stored remotely,
  efficiently, by indexing their chunk byte-ranges as a virtual Zarr store —
  kerchunk/VirtualiZarr-style — and reading through zarr-matlab with
  consolidated metadata + HTTP Range requests.

Both goals need HDF5's two missing-from-Zarr features (links, object
references); both use hdmf-zarr's JSON conventions as the shared
representation.

## 1. Architecture

```
MatNWB backend (future)      matzarr reader (.mat semantics)      ← applications
        \                       /            \
    hdmf-zarr-matlab (conventions)      matzarr indexer (HDF5 → manifest)
     zarr_link / zarr_dtype refs               |
                    \                          |
                     zarr-matlab  (+ ManifestStore, zlib, shuffle)  ← foundation
```

### Repos

| Repo | Contents | Rationale |
|---|---|---|
| `catalystneuro/zarr-matlab` (existing) | + `ManifestStore`, `ZlibCodec`, `ShuffleCodec` | all three are generic zarr-ecosystem concepts (kerchunk-style stores, numcodecs codecs); keep core domain-neutral |
| `catalystneuro/hdmf-zarr-matlab` (new) | link/reference conventions layer | mirrors python's zarr-python/hdmf-zarr split; two consumers (NWB, matzarr) |
| `catalystneuro/matzarr` (new) | `.mat`→manifest indexer + MATLAB-semantics reader | the product for G2 |

MatNWB integration is a fourth phase living in MatNWB itself (needs its I/O
layer abstracted); not scheduled here beyond a design doc.

## 2. Formats (concrete)

### 2.1 The index store ("virtual zarr")

Indexing `data.mat` produces a sidecar directory (or zip) `data.mat.zarr/`:

```
data.mat.zarr/
  zarr.json                  # root group; consolidated_metadata for ALL nodes
  <path>/zarr.json           # ordinary Zarr v3 array metadata per dataset
  manifest.json              # chunk key -> byte range in the original file
```

Everything except `manifest.json` is plain Zarr v3 — any v3 reader sees valid
metadata. `manifest.json` (aligned field-for-field with VirtualiZarr's
`ChunkManifest` so a thin Python shim can load it):

```json
{
  "manifest_format": 1,
  "default_path": "../data.mat",
  "chunks": {
    "raw/c/0/0":  {"path": "../data.mat", "offset": 4096, "length": 65536},
    "meta/c/0":   {"inline": "<base64>"}
  }
}
```

- `path` is relative to the manifest (or absolute URI); `offset`/`length`
  locate the *encoded* HDF5 chunk.
- `inline` carries small or synthesized values — notably **translated
  object-reference datasets**, which cannot be byte-range views because raw
  HDF5 reference tokens are file-internal.
- Consolidated metadata means the whole structure (incl. every `/#refs#`
  entry) is **one read**; each data access is then one ranged read per chunk.

### 2.2 HDF5 filter → Zarr codec mapping

| HDF5 filter | Zarr v3 codec (name written) | Impl |
|---|---|---|
| deflate | `numcodecs.zlib` `{level}` | Java Inflater (zlib framing) — new in zarr-matlab |
| shuffle | `numcodecs.shuffle` `{elementsize}` | pure MATLAB reshape — new in zarr-matlab |
| none / contiguous dataset | `bytes` only; contiguous = one chunk | exists |
| fletcher32, scaleoffset, szip | **error with named filter** (P2 if demanded) | — |

Using the `numcodecs.*` registered names keeps the index readable by
zarr-python out of the box.

### 2.3 References and links (shared convention, from hdmf-zarr)

- Group links: `zarr_link` attribute — list of `{name, source, path,
  object_id, source_object_id}`; `source: "."` internal, else relative path
  to another store.
- Reference datasets: `zarr_dtype: "object"` attribute; elements are
  JSON-serialized `{source, path}` dicts in a `string`-dtype array (PR #325
  encoding).
- Reference attributes: `{"zarr_dtype": "object", "value": {...}}`.

The **indexer** resolves every HDF5 object reference to its target path and
materializes these JSON forms inline in the manifest.

### 2.4 `.mat` semantics (MATLAB_class attribute → MATLAB value)

| MATLAB_class | Storage | Reader action |
|---|---|---|
| double…uint64, single | array | direct (dtype from HDF5 type) |
| char | uint16 array | `char()` decode |
| logical | uint8 + attr | `logical()` |
| cell | reference array into `/#refs#` | resolve refs (hdmf layer), recurse |
| struct (scalar & arrays) | group with field datasets / MATLAB_fields | build struct, recurse |
| string | refs-based (v7.3 encoding) | decode; verify exact layout in M0 |
| sparse | MATLAB_sparse: data/ir/jc | P2 (reconstruct sparse) |
| function_handle, classdef objects | opaque | clear error naming the variable |

Empty arrays (`MATLAB_empty`), scalars, N-D — handled in M2 test matrix.

## 3. Public APIs (targets)

```matlab
% zarr-matlab additions (v0.3)
store = zarr.stores.ManifestStore("data.mat.zarr");            % local or...
store = zarr.stores.ManifestStore("https://x/data.mat.zarr");  % ...remote (ranged reads)
zarr.codecs.ZlibCodec(level); zarr.codecs.ShuffleCodec(elementsize)

% matzarr
matzarr.index("data.mat")                    % -> data.mat.zarr sidecar
m = matzarr.open("https://bucket/data.mat.zarr");
m.who                                        % variable names, one metadata read
x = m.bigMatrix(1e6:2e6, 1:10);              % ranged reads only
c = m.myCell{3};                             % reference resolution, lazy

% hdmf-zarr-matlab
f = hdmf.zarr.open(store);                   % navigable, link/ref-resolving
n = f.resolve("/acquisition/ts1/data");      % follows zarr_link transparently
r = f.deref(ref);                            % ZarrReference -> node
```

## 4. Testing strategy (the proven zarr-matlab pattern)

1. **Self round trip (matzarr):** MATLAB script builds a `.mat` covering the
   full type matrix → `matzarr.index` → `matzarr.open` → `isequaln` against
   the original in-memory variables. The oracle is MATLAB's own `save`/`load`.
2. **Cloud path:** serve the `.mat` + index with `python -m http.server`;
   assert correctness AND request counts (probe store): metadata = 1 request,
   slice = intersecting chunks only. Reuses zarr-matlab's HTTP test harness.
3. **Python cross-check:** shim loads `manifest.json` into
   VirtualiZarr/fsspec; zarr-python reads the same values → proves the
   manifest alignment is real.
4. **hdmf-zarr-matlab:** fixtures generated by the PR #325 branch (pinned
   SHA) covering links/refs/compound/specs; reverse direction validated with
   **pynwb validation** in CI.
5. **Docs run in the tests** from day one (port `TestDocs.m`).
6. CI: clone of zarr-matlab's 4-job matrix; zarr-matlab consumed as a
   pinned dependency.

## 5. Milestones

| # | Deliverable | Acceptance criteria |
|---|---|---|
| **M0** | **De-risking spike** | ✅ **GO** (spike/m0_spike.m, 2026-07-03). Findings baked into the design below. |
| **M1** | zarr-matlab v0.3 | `ManifestStore` + `numcodecs.zlib`/`numcodecs.shuffle` codecs, tested (incl. zarr-python reading a store that uses them); ships independently |
| **M2** | matzarr alpha | index+read: numeric/char/logical/cell/struct/empty; full self-round-trip matrix green; HTTP request-count assertions; VirtualiZarr shim |
| **M3** | hdmf-zarr-matlab read (NWB) | opens PR-#325-written NWB-Zarr; resolves all links/refs; walks a real ecephys file |
| **M4** | hdmf-zarr-matlab write | MATLAB-written NWB-Zarr passes pynwb validation round trip |
| **M5** | Polish & release | sparse (P2 call), error surface for exotic types, docs sites, `.mltbx` releases, File Exchange |
| **M6** | MatNWB design doc | I/O abstraction proposal for MatNWB maintainers (coordination, not code) |

Order note: M1+M2 (the .mat goal) come before M3+M4 because they're
self-oracle'd (no dependency on the unmerged PR) and deliver standalone value.

## 5b. M0 spike findings (verified on R2024b / HDF5 1.10.11)

1. **MATLAB does not wrap `H5Dget_chunk_info`** — but a ~60-line MEX linking
   MATLAB's *bundled* `libhdf5` works perfectly (`spike/h5chunks_mex.c`).
   Two gotchas encoded there: pass a real dataspace id (this HDF5 build
   rejects `H5S_ALL`), and ids from `H5D.open` are `H5ML.id.identifier`
   int64s, usable directly.
2. **`.mat` v7.3 files have a 512-byte userblock** — every chunk address
   from the C API needs `+ userblock` (query via `H5P.get_userblock`) to
   become a file offset. This was the one genuinely surprising bug source.
3. **Deflate chunks are plain zlib** (`78 5E`, level 3, filter marked
   *optional* — so per-chunk `filter_mask` must be honored: a chunk that
   skipped deflate is stored raw). All 150 chunks of a 9.6 MB array decoded
   and reassembled byte-exactly.
4. **Dimension order is free**: MATLAB stores arrays column-major with dims
   recorded flipped, so the HDF5-C-order chunk stream is *already*
   MATLAB-order. The index emits shape in file order and matzarr presents
   the flipped dims — zero permutes on the read path.
5. **Cell references resolve cleanly**: `H5D.read` yields 8-byte tokens;
   `H5R.get_name` maps each to its `/#refs#/...` path — exactly what the
   indexer needs to materialize hdmf-style JSON refs.
6. **Ranged HTTP fetch + zlib decode == local read**, via the existing
   `HttpStore.getPartial` path. The manifest mechanics work end to end.

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| PR #325 unmerged; conventions could shift | pin fixtures to branch SHA; engage hdmf-zarr maintainers early — a second implementation is exactly the feedback that stabilizes a convention |
| Existing NWB-Zarr data (DANDI) is Zarr **v2** | out of scope initially (zarr-matlab is v3-only); revisit only on concrete demand |
| `H5D.get_chunk_info` availability/behavior | M0 verifies; fallback is `H5D.get_num_chunks` iteration or a one-time Python indexing helper |
| Huge cell arrays → huge inline manifests / consolidated metadata | measure in M2; manifests zip well; shard the manifest file if needed (format v2) |
| Indexing *remote* files (index must read the HDF5 B-tree) | assume index-at-rest (created where the file is local, e.g. at upload); remote indexing is P2 |
| Exotic `.mat` contents (objects, function handles) | defined error surface with variable names; never silent corruption |
| VirtualiZarr manifest drift | alignment is one shim + one CI test; if the zarr chunk-manifest spec lands, adopt it as format v2 |

## 7. Immediate next actions

1. Run **M0 spike** (needs only this machine: MATLAB + a generated `.mat`).
2. On GO: create the two repos, port zarr-matlab's CI/test/docs scaffolding.
3. Open a short issue on hdmf-zarr announcing the MATLAB conventions
   implementation and asking to be pinged on convention-affecting changes to
   PR #325.
