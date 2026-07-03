function m0_spike()
%M0_SPIKE De-risk the .mat-as-virtual-zarr plan. Four questions:
%  A. Does H5D.get_chunk_info yield chunk byte ranges on a real v7.3 file?
%  B. Do deflate chunks decode via plain zlib, byte-exact, with zarr-style
%     C-order chunk semantics (incl. edge padding)?
%  C. Can cell-array object references be enumerated and resolved to paths?
%  D. Does manifest-style ranged access work over HTTP via zarr-matlab's
%     HttpStore against the ORIGINAL .mat bytes?

work = fullfile(tempdir, "matzarr_spike");
if isfolder(work), rmdir(work, 's'); end
mkdir(work);
cleanup = onCleanup(@() rmdirIf(work));

% ---- build a representative v7.3 file --------------------------------
big = reshape((1:1.2e6) * 0.5, [1000 1200]);   % non-square: catches dim flips
c = {int8([1 2 3]), 'hello', struct('a', 5)};
s = struct('x', 1:10, 'name', 'abc');
lg = logical([1 0 1]);
matPath = char(fullfile(work, 'spike.mat'));
save(matPath, 'big', 'c', 's', 'lg', '-v7.3');

fid = H5F.open(matPath, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
closer = onCleanup(@() H5F.close(fid));
% .mat v7.3 = HDF5 with a userblock; chunk addresses are relative to the
% HDF5 superblock, so every file offset needs this added:
fcpl = H5F.get_create_plist(fid);
userblock = H5P.get_userblock(fcpl);
fprintf('userblock: %d bytes\n', userblock);

% ---- A: chunk info (via MEX: MATLAB does not wrap H5Dget_chunk_info) ---
here = fileparts(mfilename('fullpath'));
if isempty(which('h5chunks_mex'))
    mex('-silent', fullfile(here, 'h5chunks_mex.c'), ...
        ['-L' fullfile(matlabroot, 'bin', computer('arch'))], '-lhdf5', ...
        '-outdir', here);
end

dset = H5D.open(fid, '/big');
space = H5D.get_space(dset);
[~, h5dims] = H5S.get_simple_extent_dims(space);
plist = H5D.get_create_plist(dset);
[~, chunkDimsRaw] = H5P.get_chunk(plist);
nFilters = H5P.get_nfilters(plist);
filterIds = zeros(1, nFilters);
for i = 0:nFilters - 1
    filterIds(i + 1) = H5P.get_filter(plist, i);
end
h5dims = double(h5dims(:)');
chunkDimsRaw = double(chunkDimsRaw(:)');
[addrs, sizes, filtMasks, offs] = h5chunks_mex(int64(dset.identifier), ...
    numel(h5dims), int64(space.identifier));
nChunks = numel(addrs);
fprintf('A: dims=[%s] chunk=[%s] filters=[%s] nchunks=%d\n', ...
    num2str(h5dims), num2str(chunkDimsRaw), num2str(filterIds), nChunks);
assert(nChunks > 1, 'expected multiple chunks');
assert(any(filterIds == 1), 'expected deflate (H5Z_FILTER_DEFLATE=1)');
assert(all(filtMasks == 0), 'no chunk skipped its filters');

info = struct('offset', {}, 'addr', {}, 'size', {});
for k = 1:nChunks
    info(k) = struct('offset', double(offs(k, :)), ...
        'addr', double(addrs(k)) + userblock, 'size', double(sizes(k)));
end
fprintf('A PASS: got %d chunk byte ranges (first: addr=%d size=%d)\n', ...
    numel(info), info(1).addr, info(1).size);

% ---- B: zlib-decode every chunk, reassemble with zarr chunk math ------
% Chunk byte streams are C-order over the file's (C-order) dims. The MEX
% returns offsets exactly as the C API does; whether MATLAB's wrapper
% functions report dims flipped is settled empirically below.
mfid = fopen(matPath, 'r');
decoded = cell(1, numel(info));
for k = 1:numel(info)
    fseek(mfid, info(k).addr, 'bof');
    raw = fread(mfid, info(k).size, '*uint8')';
    decoded{k} = typecast(zlibInflate(raw), 'double');
    assert(numel(decoded{k}) == prod(chunkDimsRaw), 'chunk %d: decoded size', k);
end
fclose(mfid);

full5 = [];
verdict = "";
for hyp = ["wrapper-dims-are-C-order", "wrapper-dims-are-flipped"]
    if hyp == "wrapper-dims-are-C-order"
        dimsC = h5dims; chunkC = chunkDimsRaw;
    else
        dimsC = flip(h5dims); chunkC = flip(chunkDimsRaw);
    end
    % Assemble in MATLAB (column-major) axes = reverse of C axes:
    A = nan(flip(dimsC));
    ok = true;
    for k = 1:numel(info)
        offM = flip(info(k).offset) + 1;      % MEX offset is C order
        if any(offM + flip(chunkC) - 1 > flip(dimsC) + flip(chunkC) - 1), ok = false; break; end
        chunkArr = reshape(decoded{k}, flip(chunkC));   % C-order stream -> matlab dims
        stop = min(offM + flip(chunkC) - 1, flip(dimsC));
        subs = arrayfun(@(a, b) a:b, offM, stop, 'UniformOutput', false);
        csubs = arrayfun(@(a, b) 1:(b - a + 1), offM, stop, 'UniformOutput', false);
        try
            A(subs{:}) = chunkArr(csubs{:});
        catch
            ok = false; break;
        end
    end
    if ~ok || any(isnan(A(:))), continue; end
    if isequal(A, big)
        full5 = A; verdict = hyp + " / matches original directly"; break;
    elseif isequal(A, big.')
        full5 = A.'; verdict = hyp + " / matches transpose"; break;
    end
end
assert(~isempty(full5), 'B FAIL: no dim-order hypothesis reassembles the data');
fprintf('B PASS: zlib chunks reassemble to the original (%s)\n', verdict);

% ---- C: cell array object references ----------------------------------
dc = H5D.open(fid, '/c');
refs = H5D.read(dc);                            % 8-byte reference tokens
nRefs = size(refs, 2);
targets = strings(1, nRefs);
for i = 1:nRefs
    targets(i) = string(H5R.get_name(dc, 'H5R_OBJECT', refs(:, i)));
end
H5D.close(dc);
fprintf('C: cell targets: %s\n', strjoin(targets, ", "));
assert(all(startsWith(targets, "/#refs#/")), 'refs resolve into /#refs#');
% and the target content is readable (element 2 = ''hello'' as uint16)
hello = h5read(matPath, char(targets(2)));
assert(isequal(char(hello(:)'), 'hello'), 'ref target content');
fprintf('C PASS: %d refs enumerated + resolved + target readable\n', nRefs);

% ---- D: manifest-style ranged read over HTTP ---------------------------
port = 8000 + randi(1000);
cmd = sprintf('python3 -m http.server %d --bind 127.0.0.1 --directory "%s" >/dev/null 2>&1 & echo $!', ...
    port, work);
[~, pidStr] = system(cmd);
killer = onCleanup(@() system(sprintf('kill %s >/dev/null 2>&1', strtrim(pidStr))));
pause(1);
store = zarr.stores.HttpStore(sprintf("http://127.0.0.1:%d", port));
k = 7;  % arbitrary chunk, "manifest entry" {spike.mat, addr, size}
[bytesHttp, found] = store.getPartial("spike.mat", info(k).addr, info(k).size);
assert(found && numel(bytesHttp) == info(k).size, 'ranged fetch');
assert(isequal(typecast(zlibInflate(bytesHttp), 'double'), decoded{k}), ...
    'HTTP-fetched chunk decodes identically to local read');
fprintf('D PASS: chunk fetched by byte range over HTTP + decoded == expected\n');

H5D.close(dset);
fprintf('\nM0 SPIKE: GO\n');
end

function out = zlibInflate(bytes)
inflater = java.util.zip.Inflater(false);   % zlib framing (HDF5 deflate)
baos = java.io.ByteArrayOutputStream();
ios = java.util.zip.InflaterOutputStream(baos, inflater);
ios.write(typecast(uint8(bytes(:)'), 'int8'));
ios.close();
javaMethod('end', inflater);
out = typecast(int8(baos.toByteArray())', 'uint8');
end

function rmdirIf(p)
if isfolder(p), rmdir(p, 's'); end
end
