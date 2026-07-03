function run_tests()
%RUN_TESTS Run the matzarr suite. Needs zarr-matlab on the path (sibling
%   checkout or ZARR_MATLAB_PATH env var).

root = fileparts(fileparts(mfilename('fullpath')));
zm = string(getenv('ZARR_MATLAB_PATH'));
if strlength(zm) == 0
    zm = fullfile(fileparts(root), 'zarr-matlab');
end
if ~isfolder(fullfile(zm, '+zarr'))
    error("matzarr:Setup", ...
        "zarr-matlab not found at '%s'. Clone it as a sibling or set ZARR_MATLAB_PATH.", zm);
end
addpath(char(zm), root, fullfile(root, 'tools'));
matzarr.internal.ensure_mex();

results = runtests(fullfile(root, 'tests'));
disp(table(results));
if any([results.Failed])
    error("matzarr:TestsFailed", "%d test(s) failed.", nnz([results.Failed]));
end
fprintf('%d passed, %d skipped\n', nnz([results.Passed]), ...
    nnz([results.Incomplete] & ~[results.Failed]));
end
