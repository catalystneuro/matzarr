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

if isfolder(indexDir), rmdir(indexDir, 's'); end
store = zarr.stores.LocalStore(indexDir);
zarr.create_group(store, Attributes=struct( ...
    'matzarr_format', 1, 'source', struct('file', getRelName(matPath, indexDir))));

manifestEntries = strings(0, 1);
selfChecked = false;
top = h5info(char(matPath));
walkGroup(top, "");

% manifest: chunk data lives in the ORIGINAL .mat file
manifest = "{""manifest_format"":1,""default_path"":" + ...
    string(jsonencode(char(getRelName(matPath, indexDir)))) + ...
    ",""chunks"":{" + strjoin(manifestEntries, ",") + "}}";
store.set("manifest.json", unicode2native(char(manifest), 'UTF-8'));
zarr.consolidate_metadata(store);

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

        try
            [~, h5chunk] = H5P.get_chunk(plist);
            h5chunk = reshape(double(h5chunk), 1, []);
            chunked = true;
        catch
            h5chunk = h5dims;   % contiguous or compact: one whole-array chunk
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
                raw = readRange(matPath, double(addrs(1)) + userblock, double(sizes(1)));
                try
                    pipeline.decode(raw);
                catch err
                    rawNoUb = readRange(matPath, double(addrs(1)), min(8, double(sizes(1))));
                    [vMaj, vMin, vRel] = H5.get_libversion();
                    error("matzarr:SelfCheckFailed", ...
                        "Chunk decode self-check failed for '%s': %s\n" + ...
                        "  filters=[%s] userblock=%d addr=%d size=%d hdf5=%d.%d.%d\n" + ...
                        "  first8 @addr+userblock: %s\n  first8 @addr (no userblock): %s", ...
                        nodePath, err.message, num2str(filtersSeen), userblock, ...
                        addrs(1), sizes(1), vMaj, vMin, vRel, ...
                        strjoin(string(dec2hex(raw(1:min(8, end)), 2))', " "), ...
                        strjoin(string(dec2hex(rawNoUb, 2))', " "));
                end
            end
            for k = 1:numel(addrs)
                coords = flip(double(offs(k, :)) ./ h5chunk);  % logical grid
                key = nodePath + "/" + meta.chunkKey(coords);
                if masks(k) == 0
                    addEntry(key, double(addrs(k)) + userblock, double(sizes(k)));
                else
                    % this chunk skipped some filters; normalize by re-encoding
                    raw = readRange(matPath, double(addrs(k)) + userblock, double(sizes(k)));
                    chunkArr = decodeMasked(raw, masks(k), deflateLevel, meta, info, h5chunk);
                    addInline(key, pipeline.encode(chunkArr));
                end
            end
        else
            offset = -1;
            try
                offset = H5D.get_offset(dset);
            catch
            end
            key = nodePath + "/" + meta.chunkKey(zeros(1, R));
            if offset >= 0
                addEntry(key, double(offset) + userblock, ...
                    double(H5D.get_storage_size(dset)));
            else
                % compact layout (tiny values live in object headers): inline
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

function rel = getRelName(matPath, indexDir) %#ok<INUSD>
[~, n, e] = fileparts(matPath);
rel = "../" + n + e;   % index dir sits next to the .mat file
end
