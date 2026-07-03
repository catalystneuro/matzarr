function make_shim_fixture(outDir)
%MAKE_SHIM_FIXTURE Write a deterministic .mat + index for the python shim test.

if isfolder(outDir), rmdir(outDir, 's'); end
mkdir(outDir);
big = reshape((1:6e4)' * 0.25, [200 300]); %#ok<NASGU>
labels = {'alpha', 'beta'}; %#ok<NASGU>
matPath = char(fullfile(outDir, 'fixture.mat'));
save(matPath, 'big', 'labels', '-v7.3');
matzarr.index(matPath);
fprintf('fixture written to %s\n', outDir);
end
