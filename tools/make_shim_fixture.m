function make_shim_fixture(outDir)
%MAKE_SHIM_FIXTURE Write a deterministic .mat + index for the python shim test.

if isfolder(outDir), rmdir(outDir, 's'); end
mkdir(outDir);
big = reshape((1:6e4)' * 0.25, [200 300]); %#ok<NASGU>
labels = {'alpha', 'beta'}; %#ok<NASGU>
% complex is a compound {real, imag} in the .mat file and complex128 in the
% index; reading it from zarr-python proves the byte layouts really coincide.
cplx = reshape((1:6e3)' * 0.5, [60 100]) + 1i * reshape((1:6e3)' * -0.25, [60 100]); %#ok<NASGU>
matPath = char(fullfile(outDir, 'fixture.mat'));
save(matPath, 'big', 'labels', 'cplx', '-v7.3');
matzarr.index(matPath);
fprintf('fixture written to %s\n', outDir);
end
