function probe_ids()
work = fullfile(tempdir, 'matzarr_probe');
if isfolder(work), rmdir(work, 's'); end
mkdir(work);
big = rand(100, 200);
save(fullfile(work, 'p.mat'), 'big', '-v7.3');
fid = H5F.open(fullfile(work, 'p.mat'), 'H5F_ACC_RDONLY', 'H5P_DEFAULT');
dset = H5D.open(fid, '/big');
fprintf('dset class=%s, id class=%s, id value=%.0f\n', ...
    class(dset), class(dset.identifier), double(dset.identifier));
sp = H5D.get_space(dset);
fprintf('space id value=%.0f\n', double(sp.identifier));
% does the wrapper's own call work with this id?
fprintf('storage size via wrapper: %d\n', H5D.get_storage_size(dset));
% try the MEX with the real space id instead of H5S_ALL
try
    [a, s, f, o] = h5chunks_mex(int64(dset.identifier), 2, int64(sp.identifier)); %#ok<ASGLU>
    fprintf('MEX with H5S_ALL: OK, n=%d\n', numel(a));
catch err
    fprintf('MEX with H5S_ALL failed: %s\n', err.message);
end
rmdir(work, 's');
end
