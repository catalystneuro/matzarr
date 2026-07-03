function ensure_mex()
%ENSURE_MEX Build h5chunks_mex (against MATLAB's bundled libhdf5) if absent.

if ~isempty(which('h5chunks_mex'))
    return
end
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));  % repo root
src = fullfile(root, 'mex', 'h5chunks_mex.c');
mex('-silent', src, ['-L' fullfile(matlabroot, 'bin', computer('arch'))], ...
    '-lhdf5', '-outdir', root);
rehash;
end
