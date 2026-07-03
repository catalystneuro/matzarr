function indexDir = index(matPath, indexDir)
%INDEX Build a virtual-Zarr sidecar index for a .mat (v7.3 / HDF5) file.
%   matzarr.index("data.mat") writes "data.mat.zarr" next to the file:
%   ordinary Zarr v3 metadata (consolidated) plus a manifest mapping each
%   chunk to a byte range in the original file. Read it (locally or over
%   HTTP) with matzarr.open.

arguments
    matPath (1,1) string
    indexDir (1,1) string = matPath + ".zarr"
end

if ~isfile(matPath)
    error("matzarr:FileNotFound", "No such file: %s", matPath);
end
matzarr.internal.ensure_mex();

fid = H5F.open(char(matPath), 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
closer = onCleanup(@() H5F.close(fid));
fcpl = H5F.get_create_plist(fid);
userblock = H5P.get_userblock(fcpl);
% HDF5 changed chunk-address semantics: in 1.10 H5Dget_chunk_info returns
% addresses relative to the superblock (userblock must be added); in 1.14+
% they are absolute file offsets. Pick by version, then VERIFY empirically
% (self-checks below) and fall back to the alternative if decoding fails.
[h5maj, h5min] = H5.get_libversion();
if h5maj > 1 || h5min >= 14
    chunkAddrOffset = 0;
else
    chunkAddrOffset = userblock;
end
contigAddrOffset = -1;   % resolved on first contiguous dataset

% Build all metadata in a CASE-SENSITIVE in-memory store: .mat /#refs#
% uses case-sensitive single-char names (a, A, b, B, ...) that would
% clobber each other as files on a case-insensitive filesystem (macOS
% APFS, Windows NTFS default). We consolidate in memory and persist only
% the consolidated root + manifest to disk — two files, no per-node files.
store = zarr.stores.MemoryStore();
zarr.create_group(store, Attributes=struct( ...
    'matzarr_format', 1, 'source', struct('file', getRelName(matPath, indexDir))));

manifestEntries = strings(0, 1);
selfChecked = false;
top = h5info(char(matPath));
walkGroup(top, "");

manifest = "{""manifest_format"":1,""default_path"":" + ...
    string(jsonencode(char(getRelName(matPath, indexDir)))) + ...
    ",""chunks"":{" + strjoin(manifestEntries, ",") + "}}";
zarr.consolidate_metadata(store);

if isfolder(indexDir), rmdir(indexDir, 's'); end
out = zarr.stores.LocalStore(indexDir);
[rootMeta, ~] = store.get("zarr.json");
out.set("zarr.json", rootMeta);                              % consolidated root
out.set("manifest.json", unicode2native(char(manifest), 'UTF-8'));

    % ------------------------------------------------------------------
    function walkGroup(g, prefix)
        for i = 1:numel(g.Datasets)
            ds = g.Datasets(i);
            nodePath = joinPath(prefix, ds.Name);
            try
                indexDataset(ds, nodePath);
            catch err
                if startsWith(string(err.identifier), "matzarr:")
                    rethrow(err);
                end
                error("matzarr:IndexError", "Indexing '%s' failed: %s", ...
                    nodePath, err.message);
            end
        end
        for i = 1:numel(g.Groups)
            sub = g.Groups(i);
            nodePath = zarr.internal.normalize_path(string(sub.Name));
            zarr.create_group(store, Path=nodePath, ...
                Attributes=attrStruct(sub.Attributes));
            walkGroup(sub, nodePath);
        end
    end

    function indexDataset(ds, nodePath)
        h5path = "/" + nodePath;
        attrs = attrStruct(ds.Attributes);
        [dtype, elemSize, isRef] = mapDatatype(ds.Datatype, nodePath);

        if isRef
            indexRefsDataset(h5path, nodePath, ds, attrs);
            return
        end

        % h5info reports dims in MATLAB order (already flipped from the
        % file's C order); the low-level chunk APIs below do NOT flip.
        h5dims = flip(reshape(double(ds.Dataspace.Size), 1, []));  % -> C order,
        % per the M0 finding: chunk byte streams over these dims are exactly
        % MATLAB column-major, so shape = flip(dims) + a transpose codec
        % makes reads copy-minimal and logically identical to the original.
        if isempty(h5dims)  % scalar dataspace
            h5dims = 1;
        end
        R = numel(h5dims);

        dset = H5D.open(fid, char(h5path));
        dcloser = onCleanup(@() H5D.close(dset));
        plist = H5D.get_create_plist(dset);

        % filters -> codec chain (deflate=1, shuffle=2)
        codecs = {};
        deflateLevel = [];
        filtersSeen = [];
        for f = 0:H5P.get_nfilters(plist) - 1
            [fdef, ~, cd] = H5P.get_filter(plist, f);
            filtersSeen(end + 1) = fdef; %#ok<AGROW>
            switch fdef
                case 1
                    deflateLevel = double(cd(1));
                case 2
                    codecs{end + 1} = zarr.codecs.ShuffleCodec(elemSize); %#ok<AGROW>
                otherwise
                    error("matzarr:UnsupportedFilter", ...
                        "'%s' uses HDF5 filter %d, which matzarr does not support.", ...
                        nodePath, fdef);
            end
        end
        codecs = [{zarr.codecs.BytesCodec()}, codecs];
        if ~isempty(deflateLevel)
            codecs{end + 1} = zarr.codecs.ZlibCodec(deflateLevel);
        end
        if R >= 2
            codecs = [{zarr.codecs.TransposeCodec(R - 1:-1:0)}, codecs];
        end

        % Ask HDF5 for the layout directly (0=compact 1=contiguous 2=chunked)
        % rather than inferring it from get_chunk/get_offset exceptions, which
        % misroutes compact scalars (common in .mat /#refs# entries).
        layout = H5P.get_layout(plist);
        if layout == 2
            [~, h5chunk] = H5P.get_chunk(plist);
            h5chunk = reshape(double(h5chunk), 1, []);
            chunked = true;
        else
            h5chunk = h5dims;   % contiguous / compact: one whole-array chunk
            chunked = false;
        end

        meta = zarr.metadata.ArrayMetadata();
        meta.shape = flip(h5dims);
        meta.dataType = dtype;
        meta.chunkShape = flip(h5chunk);
        meta.fillValue = zeroFill(dtype);
        meta.codecs = codecs;
        meta.attributes = attrs;
        store.set(nodePath + "/zarr.json", ...
            unicode2native(char(meta.toJsonText()), 'UTF-8'));

        info = zarr.internal.dtype_info(dtype);
        pipeline = zarr.codecs.Pipeline(codecs, info, meta.chunkShape);

        if chunked
            space = H5D.get_space(dset);
            [addrs, sizes, masks, offs] = h5chunks_mex(int64(dset.identifier), ...
                R, int64(space.identifier));
            if ~selfChecked && ~isempty(addrs) && masks(1) == 0
                % Validate the codec-chain assumption on the first real chunk
                % so a MATLAB-version change in .mat encoding fails loudly at
                % index time, with evidence, rather than corrupting reads.
                selfChecked = true;
                raw = readRange(matPath, double(addrs(1)) + chunkAddrOffset, double(sizes(1)));
                if ~tryDecode(pipeline, raw)
                    alt = userblock - chunkAddrOffset;   % the other candidate
                    raw2 = readRange(matPath, double(addrs(1)) + alt, double(sizes(1)));
                    if tryDecode(pipeline, raw2)
                        chunkAddrOffset = alt;
                    else
                        error("matzarr:SelfCheckFailed", ...
                            "Chunk decode self-check failed for '%s' at both address offsets " + ...
                            "(filters=[%s] userblock=%d addr=%d size=%d hdf5=%d.%d, " + ...
                            "first8@+%d: %s, first8@+%d: %s).", ...
                            nodePath, num2str(filtersSeen), userblock, addrs(1), sizes(1), ...
                            h5maj, h5min, chunkAddrOffset, ...
                            strjoin(string(dec2hex(raw(1:min(8, end)), 2))', " "), alt, ...
                            strjoin(string(dec2hex(raw2(1:min(8, end)), 2))', " "));
                    end
                end
            end
            for k = 1:numel(addrs)
                coords = flip(double(offs(k, :)) ./ h5chunk);  % logical grid
                key = nodePath + "/" + meta.chunkKey(coords);
                if masks(k) == 0
                    addEntry(key, double(addrs(k)) + chunkAddrOffset, double(sizes(k)));
                else
                    % this chunk skipped some filters; normalize by re-encoding
                    raw = readRange(matPath, double(addrs(k)) + chunkAddrOffset, double(sizes(k)));
                    chunkArr = decodeMasked(raw, masks(k), deflateLevel, meta, info, h5chunk);
                    addInline(key, pipeline.encode(chunkArr));
                end
            end
        elseif layout == 0
            % compact: data lives in the object header, not at a file offset
            vals = h5read(char(matPath), char(h5path));
            A = castForPipeline(vals, info, meta.shape);
            addInline(nodePath + "/" + meta.chunkKey(zeros(1, R)), pipeline.encode(A));
        else
            offset = -1;
            try
                offset = H5D.get_offset(dset);
            catch
            end
            key = nodePath + "/" + meta.chunkKey(zeros(1, R));
            if offset >= 0 && double(H5D.get_storage_size(dset)) > 0
                storage = double(H5D.get_storage_size(dset));
                if contigAddrOffset < 0
                    % Resolve contiguous-offset semantics once per file by
                    % validating decoded bytes against h5read.
                    expected = castForPipeline(h5read(char(matPath), char(h5path)), ...
                        info, meta.shape);
                    for cand = unique([chunkAddrOffset, 0, userblock])
                        rawC = readRange(matPath, double(offset) + cand, storage);
                        [ok, A] = tryDecode(pipeline, rawC);
                        if ok && isequaln(A, expected)
                            contigAddrOffset = cand;
                            break
                        end
                    end
                    if contigAddrOffset < 0
                        error("matzarr:SelfCheckFailed", ...
                            "Contiguous dataset '%s' did not validate at any address offset.", ...
                            nodePath);
                    end
                end
                addEntry(key, double(offset) + contigAddrOffset, storage);
            else
                % zero-storage (e.g. empty) contiguous dataset: inline
                vals = h5read(char(matPath), char(h5path));
                A = castForPipeline(vals, info, meta.shape);
                addInline(key, pipeline.encode(A));
            end
        end
    end

    function indexRefsDataset(h5path, nodePath, ds, attrs)
        % Object references (cell arrays, struct-array fields): translate to
        % hdmf-zarr style JSON refs in a string-dtype array, stored inline.
        h5dims = flip(reshape(double(ds.Dataspace.Size), 1, []));  % C order
        if isempty(h5dims), h5dims = 1; end
        R = numel(h5dims);
        dset = H5D.open(fid, char(h5path));
        dcloser = onCleanup(@() H5D.close(dset));
        refs = H5D.read(dset);
        n = prod(h5dims);
        jsonRefs = strings(n, 1);
        for i = 1:n
            target = string(H5R.get_name(dset, 'H5R_OBJECT', refs(:, i)));
            jsonRefs(i) = string(jsonencode(struct('source', '.', 'path', char(target))));
        end
        % C-order element stream over h5dims == column-major over flip(h5dims)
        A = reshape(jsonRefs, [flip(h5dims), 1, 1]);

        attrs.zarr_dtype = 'object';
        meta = zarr.metadata.ArrayMetadata();
        meta.shape = flip(h5dims);
        meta.dataType = "string";
        meta.chunkShape = flip(h5dims);
        meta.fillValue = "";
        meta.codecs = {zarr.codecs.VlenUtf8Codec(), zarr.codecs.ZlibCodec(3)};
        meta.attributes = attrs;
        store.set(nodePath + "/zarr.json", ...
            unicode2native(char(meta.toJsonText()), 'UTF-8'));
        info = zarr.internal.dtype_info("string");
        pipeline = zarr.codecs.Pipeline(meta.codecs, info, meta.chunkShape, "");
        addInline(nodePath + "/" + meta.chunkKey(zeros(1, R)), pipeline.encode(A));
    end

    function addEntry(key, offset, len)
        manifestEntries(end + 1) = """" + key + """:{""offset"":" + ...
            sprintf('%d', offset) + ",""length"":" + sprintf('%d', len) + "}";
    end

    function addInline(key, bytes)
        manifestEntries(end + 1) = """" + key + """:{""inline"":""" + ...
            string(matlab.net.base64encode(uint8(bytes))) + """}";
    end
end

% ---------------------------------------------------------------------
function s = attrStruct(attrList)
s = struct();
for i = 1:numel(attrList)
    name = attrList(i).Name;
    if ~isvarname(name), continue; end
    v = attrList(i).Value;
    if iscell(v) && isscalar(v), v = v{1}; end
    s.(name) = v;
end
end

function [dtype, elemSize, isRef] = mapDatatype(dt, nodePath)
isRef = false;
elemSize = double(dt.Size);
switch dt.Class
    case 'H5T_FLOAT'
        switch elemSize
            case 4, dtype = "float32";
            case 8, dtype = "float64";
            otherwise
                error("matzarr:UnsupportedType", "'%s': float%d", nodePath, elemSize * 8);
        end
    case 'H5T_INTEGER'
        t = string(dt.Type);   % e.g. 'H5T_STD_U16LE'
        signed = contains(t, "_I");
        bits = elemSize * 8;
        if signed, dtype = "int" + bits; else, dtype = "uint" + bits; end
        if ~endsWith(t, "LE")
            error("matzarr:UnsupportedType", "'%s': big-endian data", nodePath);
        end
    case 'H5T_REFERENCE'
        dtype = "string";
        isRef = true;
    case 'H5T_COMPOUND'
        error("matzarr:UnsupportedType", ...
            "'%s' is compound (complex or table data) — not yet supported.", nodePath);
    otherwise
        error("matzarr:UnsupportedType", "'%s': HDF5 class %s", nodePath, dt.Class);
end
end

function v = zeroFill(dtype)
info = zarr.internal.dtype_info(dtype);
if dtype == "string"
    v = "";
elseif info.zarrType == "bool"
    v = false;
else
    v = cast(0, char(info.matlabClass));
end
end

function A = castForPipeline(vals, info, shape)
A = cast(vals, char(info.matlabClass));
A = reshape(A, zarr.internal.mshape(shape));
end

function chunkArr = decodeMasked(raw, mask, deflateLevel, meta, info, h5chunk)
% filter_mask bit i set => filter i was SKIPPED for this chunk.
bytes = raw;
if bitand(mask, 1) == 0 && ~isempty(deflateLevel)
    bytes = zarr.internal.zlib_java('decompress', bytes);
end
% (shuffle skipped-chunk handling would go here; deflate-only in practice)
v = typecast(uint8(bytes(:)'), char(info.matlabClass));
chunkArr = reshape(v, zarr.internal.mshape(flip(h5chunk)));
end

function [ok, A] = tryDecode(pipeline, bytes)
A = [];
try
    A = pipeline.decode(bytes);
    ok = true;
catch
    ok = false;
end
end

function raw = readRange(path, offset, len)
fh = fopen(path, 'r');
cleaner = onCleanup(@() fclose(fh));
fseek(fh, offset, 'bof');
raw = fread(fh, len, '*uint8')';
end

function p = joinPath(prefix, name)
if strlength(prefix) == 0
    p = zarr.internal.normalize_path(string(name));
else
    p = prefix + "/" + zarr.internal.normalize_path(string(name));
end
end

function rel = getRelName(matPath, indexDir)
% Relative path FROM the index dir TO the .mat file, so a moved
% (index, file) pair still resolves. Falls back to an absolute path when
% the two live on different drives (Windows) or share no common root.
matAbs = absPath(matPath);
idxAbs = absPath(indexDir);
mp = split(matAbs, "/");
ip = split(idxAbs, "/");
mp = mp(strlength(mp) > 0);
ip = ip(strlength(ip) > 0);
k = 0;
while k < min(numel(mp), numel(ip)) - 1 && mp(k + 1) == ip(k + 1)
    k = k + 1;
end
if k == 0 && ~startsWith(matAbs, "/")
    rel = matAbs;   % no shared root (e.g. different Windows drives)
    return
end
ups = repmat("..", 1, numel(ip) - k);   % ip includes the index dir itself
downs = mp(k + 1:end);
rel = strjoin([ups(:); downs(:)], "/");
end

function p = absPath(p)
p = string(p);
if ~(startsWith(p, "/") || ~isempty(regexp(p, '^[A-Za-z]:', 'once')))
    p = string(fullfile(pwd, char(p)));
end
p = strrep(p, "\", "/");
end
