function probe_bytes()
run_all();
probe_userblock();
end
function run_all()
work = fullfile(tempdir, 'matzarr_probe2');
if isfolder(work), rmdir(work, 's'); end
mkdir(work);
big = reshape((1:1.2e6) * 0.5, [1000 1200]);
matPath = char(fullfile(work, 'p.mat'));
save(matPath, 'big', '-v7.3');
fid = H5F.open(matPath, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
dset = H5D.open(fid, '/big');
space = H5D.get_space(dset);
plist = H5D.get_create_plist(dset);
nf = H5P.get_nfilters(plist);
for i = 0:nf - 1
    [fdef, flags, cd] = H5P.get_filter(plist, i);
    fprintf('filter %d: id=%d flags=%d cd=[%s]\n', i, fdef, flags, num2str(cd(:)'));
end
[addrs, sizes, ~, offs] = h5chunks_mex(int64(dset.identifier), 2, int64(space.identifier));
mfid = fopen(matPath, 'r');
for k = 1:min(3, numel(addrs))
    fseek(mfid, double(addrs(k)), 'bof');
    head = fread(mfid, 8, '*uint8')';
    fprintf('chunk %d: off=[%s] addr=%d size=%d first8=%s\n', k, ...
        num2str(double(offs(k, :))), addrs(k), sizes(k), ...
        strjoin(string(dec2hex(head, 2))', ' '));
end
fclose(mfid);
fprintf('file size: %d, storage_size: %d\n', dir(matPath).bytes, ...
    H5D.get_storage_size(dset));
end

function probe_userblock()
work = fullfile(tempdir, 'matzarr_probe2');
matPath = char(fullfile(work, 'p.mat'));
fid = H5F.open(matPath, 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
fcpl = H5F.get_create_plist(fid);
ub = H5P.get_userblock(fcpl);
fprintf('userblock: %d bytes\n', ub);
dset = H5D.open(fid, '/big');
space = H5D.get_space(dset);
[addrs, sizes] = h5chunks_mex(int64(dset.identifier), 2, int64(space.identifier));
mfid = fopen(matPath, 'r');
fseek(mfid, double(addrs(1)) + ub, 'bof');
head = fread(mfid, 4, '*uint8')';
fclose(mfid);
fprintf('chunk 1 at addr+userblock, first4: %s\n', strjoin(string(dec2hex(head, 2))', ' '));
end
